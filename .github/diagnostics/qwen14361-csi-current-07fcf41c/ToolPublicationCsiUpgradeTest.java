package com.alibaba.qwen.code.managedagent;

import com.alibaba.qwen.code.managedagent.contracts.artifact.ToolPublicationObjectStore;
import com.alibaba.qwen.code.managedagent.contracts.persistence.ToolPublicationContract;
import com.alibaba.qwen.code.managedagent.contracts.persistence.WorkspaceCsiRegistration;
import com.alibaba.qwen.code.managedagent.exception.ManagedAgentException;
import com.alibaba.qwen.code.managedagent.persistence.ToolPublicationDataStore;
import com.alibaba.qwen.code.managedagent.persistence.WorkspaceCsiReservationStore;
import com.alibaba.qwen.code.runtimebroker.ToolExecutionRecord;
import com.alibaba.qwen.code.runtimebroker.managedschema.ManagedSchema;
import com.alibaba.qwen.code.runtimebroker.managedschema.ManagedSchemaTime;
import com.alibaba.qwen.code.runtimebroker.persistence.JdbcRuntimeSessionRepository;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import javax.sql.DataSource;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;

import static com.alibaba.qwen.code.managedagent.PublicationJournalFixture.PUBLICATION_TOKEN;
import static com.alibaba.qwen.code.managedagent.persistence.PublicationVerification.verified;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ToolPublicationCsiUpgradeTest {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final WorkspaceCsiRegistration CSI = new WorkspaceCsiRegistration(
            "tenant-1", "fixture-storage", "fixture-cluster", "fixture", "fixture-claim", "fixture-pvc",
            "fixture-volume", "fixture-pv", "fixture.csi", "fixture-handle", "fixture-backend", "fixture-serial",
            "/workspace", 1);
    private static final String PUBLICATION = "pub-1";
    private static final String STDOUT = "seg-stdout-0";
    private static final byte[] OUTPUT = "legacy-csi-upgrade-stdout".getBytes(StandardCharsets.UTF_8);
    private static final byte[] ERROR = "fresh-csi-upgrade-stderr".getBytes(StandardCharsets.UTF_8);
    private static final String DIGEST = sha256(OUTPUT);

    @Test
    void createLegacySettledPublication() throws IOException {
        var source = source("legacy");
        var bucket = new FileBucket(root().resolve("legacy-objects"));
        var journal = initialize(source);
        var execution = authorize(journal, source);
        csi(journal).beginRetirement(CSI, journal.bindings, journal.bindings.findById("binding-1"),
                journal.csiReservation, UUID.randomUUID().toString());
        var data = data(journal, bucket);
        JsonNode key = journal.binding.get("sessionKey");
        JsonNode receipt = verified(data).publishSegment(key, PUBLICATION, PUBLICATION_TOKEN,
                STDOUT, "stdout", 0, OUTPUT, DIGEST);
        assertThat(receipt.path("kind").asText()).isEqualTo("managed-tool-segment");
        assertThat(receipt.path("resourceId").asText()).startsWith("capture-segment-");
        assertThat(receipt.path("schemaVersion").asInt()).isEqualTo(1);
        assertThat(receipt.path("byteLength").asInt()).isEqualTo(OUTPUT.length);
        assertThat(receipt.path("digest").asText()).isEqualTo(DIGEST);
        assertThat(receipt.has("captureId") || receipt.has("streamId") || receipt.has("ordinal")).isFalse();

        ObjectNode terminal = JSON.createObjectNode().put("executionStatus", "success");
        terminal.putArray("responseParts").addObject().put("score", 0.5);
        terminal.putObject("capture").put("captureStatus", "unavailable")
                .put("captureReason", "storage_failed").put("previewTruncated", false)
                .put("deliveryStatus", "pending").putNull("manifest");
        verified(data).finish(key, PUBLICATION, PUBLICATION_TOKEN, "finish-1",
                JSON.writeValueAsBytes(terminal));
        journal.executions.compareAndSet(execution,
                execution.withResult(JSON.convertValue(terminal, new TypeReference<Map<String, Object>>() {}),
                        0, Instant.now()),
                "dispatcher", execution.getDispatchGeneration());

        assertSettled(journal);
        JsonNode original = data.operationStatus(key, PUBLICATION, PUBLICATION_TOKEN, STDOUT);
        assertThat(original.path("state").asText()).isEqualTo("SUCCEEDED");
        assertThat(original.path("receipt")).isEqualTo(receipt);
        assertThat(bucket.reads).isPositive();
        assertThat(bucket.puts).isPositive();
        ObjectNode evidence = identity(journal, bucket);
        evidence.set("binding", journal.binding);
        evidence.set("status", original);
        write("legacy.json", evidence);
    }

    @Test
    void replayLegacyAndVerifyFreshReceiptsAfterUpgrade() throws IOException {
        JsonNode prior = JSON.readTree(root().resolve("legacy.json").toFile());
        var bucket = new FileBucket(root().resolve("legacy-objects"));
        var journal = PublicationJournalFixture.reopenForCsiUpgrade(source("legacy"));
        var data = data(journal, bucket);
        ObjectNode key = (ObjectNode) prior.path("binding").path("sessionKey");
        JsonNode original = prior.path("status");
        assertThat(ProcessHandle.current().pid()).isNotEqualTo(prior.path("pid").asLong());
        assertThat(ProcessHandle.current().info().startInstant().orElseThrow().toString())
                .isNotEqualTo(prior.path("runtimeStart").asText());
        assertThat(serializerDigest()).isNotEqualTo(prior.path("serializerSha256").asText());
        assertSettled(journal);
        assertUnchanged(journal, bucket, prior);

        JsonNode status = data.operationStatus(key, PUBLICATION, PUBLICATION_TOKEN, STDOUT);
        JsonNode post = data.publishSegment(key, PUBLICATION, PUBLICATION_TOKEN,
                STDOUT, "stdout", 0, OUTPUT, DIGEST);
        JsonNode recovered = data.recoverOperation(key, PUBLICATION, PUBLICATION_TOKEN, STDOUT);
        assertThat(status).isEqualTo(original);
        assertThat(post).isEqualTo(original);
        assertThat(recovered).isEqualTo(original);

        byte[] changed = "changed".getBytes(StandardCharsets.UTF_8);
        assertThatThrownBy(() -> data.publishSegment(key, PUBLICATION, PUBLICATION_TOKEN,
                STDOUT, "stdout", 0, changed, DIGEST)).isInstanceOfSatisfying(ManagedAgentException.class,
                        failure -> assertThat(failure.getStatus()).isEqualTo(400));
        assertThatThrownBy(() -> data.publishSegment(key, PUBLICATION, PUBLICATION_TOKEN,
                STDOUT, "stdout", 0, changed, sha256(changed))).hasMessageContaining("operation conflicts");
        assertThatThrownBy(() -> data.publishSegment(key, PUBLICATION, PUBLICATION_TOKEN,
                STDOUT, "stderr", 0, OUTPUT, DIGEST)).hasMessageContaining("operation conflicts");
        assertThatThrownBy(() -> data.publishSegment(key, PUBLICATION, PUBLICATION_TOKEN,
                "unknown-alias", "stdout", 0, OUTPUT, DIGEST)).hasMessageContaining("Original");
        assertThatThrownBy(() -> data.recoverOperation(key, PUBLICATION, PUBLICATION_TOKEN,
                "unknown-alias")).hasMessageContaining("operation is missing");
        assertThatThrownBy(() -> data.operationStatus(key, PUBLICATION, PUBLICATION_TOKEN,
                "unknown-alias")).isInstanceOfSatisfying(ManagedAgentException.class,
                        failure -> assertThat(failure.getStatus()).isEqualTo(404));
        String wrongToken = "B".repeat(42) + "A";
        assertThatThrownBy(() -> data.operationStatus(key, PUBLICATION, wrongToken, STDOUT))
                .hasMessageContaining("scope conflicts");
        assertThatThrownBy(() -> data.publishSegment(key, PUBLICATION, wrongToken,
                STDOUT, "stdout", 0, OUTPUT, DIGEST)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> data.recoverOperation(key, PUBLICATION, wrongToken, STDOUT))
                .isInstanceOf(IllegalArgumentException.class);
        ObjectNode wrongScope = key.deepCopy().put("sessionId", "different-session");
        assertThatThrownBy(() -> data.operationStatus(wrongScope, PUBLICATION, PUBLICATION_TOKEN, STDOUT))
                .isInstanceOfSatisfying(ManagedAgentException.class,
                        failure -> assertThat(failure.getStatus()).isEqualTo(404));
        assertThatThrownBy(() -> data.publishSegment(wrongScope, PUBLICATION, PUBLICATION_TOKEN,
                STDOUT, "stdout", 0, OUTPUT, DIGEST)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> data.recoverOperation(wrongScope, PUBLICATION, PUBLICATION_TOKEN, STDOUT))
                .isInstanceOf(IllegalArgumentException.class);
        assertUnchanged(journal, bucket, prior);

        ObjectNode evidence = identity(journal, bucket);
        evidence.set("status", status);
        evidence.set("exactPost", post);
        evidence.set("recover", recovered);
        assertThat(journal.jdbc.update("UPDATE ma_output_capture SET expires_at = 0")).isEqualTo(1);
        assertThatThrownBy(() -> data.publishSegment(key, PUBLICATION, PUBLICATION_TOKEN,
                STDOUT, "stdout", 0, OUTPUT, DIGEST)).hasMessageContaining("grant changed or expired");
        assertThatThrownBy(() -> data.recoverOperation(key, PUBLICATION, PUBLICATION_TOKEN, STDOUT))
                .hasMessageContaining("grant changed or expired");
        JsonNode expiredStatus = data.operationStatus(key, PUBLICATION, PUBLICATION_TOKEN, STDOUT);
        assertThat(expiredStatus).isEqualTo(original);
        evidence.set("statusAfterExpiry", expiredStatus);
        assertThat(bucket.reads).isZero();
        assertThat(bucket.puts).isZero();
        write("replay.json", evidence);

        var freshSource = source("fresh");
        var fresh = initialize(freshSource);
        authorize(fresh, freshSource);
        var freshData = data(fresh, new FileBucket(root().resolve("fresh-objects")));
        ObjectNode freshEvidence = JSON.createObjectNode();
        freshEvidence.set("binding", fresh.binding);
        freshEvidence.set("stdout", freshStatus(fresh, freshData, "stdout", OUTPUT));
        freshEvidence.set("stderr", freshStatus(fresh, freshData, "stderr", ERROR));
        write("fresh.json", freshEvidence);
    }

    private static JsonNode freshStatus(PublicationJournalFixture journal,
            ToolPublicationDataStore data, String stream, byte[] bytes) {
        JsonNode key = journal.binding.get("sessionKey");
        String operation = "seg-" + stream + "-0";
        JsonNode receipt = verified(data).publishSegment(key, PUBLICATION, PUBLICATION_TOKEN,
                operation, stream, 0, bytes, sha256(bytes));
        assertThat(receipt).isEqualTo(JSON.createObjectNode().put("captureId", "capture-1")
                .put("streamId", stream).put("ordinal", 0).put("byteLength", bytes.length)
                .put("digest", sha256(bytes)));
        JsonNode status = data.operationStatus(key, PUBLICATION, PUBLICATION_TOKEN, operation);
        assertThat(status.path("receipt")).isEqualTo(receipt);
        assertThat(data.publishSegment(key, PUBLICATION, PUBLICATION_TOKEN, operation,
                stream, 0, bytes, sha256(bytes))).isEqualTo(status);
        return status;
    }

    private static PublicationJournalFixture initialize(DataSource source) {
        ManagedSchema.initialize(source);
        return PublicationJournalFixture.create(source, CSI);
    }

    private static ToolExecutionRecord authorize(PublicationJournalFixture journal, DataSource source) {
        journal.reserve();
        var prepared = journal.executions.findByExecutionCallId("execution-1");
        assertThat(journal.store.verifyDispatch(prepared, PUBLICATION, PUBLICATION_TOKEN)).isEqualTo(journal.binding);
        var claim = journal.executions.claimDispatch("execution-1", "dispatcher", Duration.ofMinutes(1));
        return journal.bindings.authorizeDispatch(new JdbcRuntimeSessionRepository(source), journal.executions,
                claim, "dispatcher", claim.getDispatchGeneration());
    }

    private static WorkspaceCsiReservationStore csi(PublicationJournalFixture journal) {
        return new WorkspaceCsiReservationStore(journal.jdbc, journal.manager, JSON);
    }

    private static void assertSettled(PublicationJournalFixture journal) {
        assertThat(csi(journal).inspect(CSI).phase()).isEqualTo("DRAINING");
        assertThat(journal.executions.findByExecutionCallId("execution-1").getState())
                .isEqualTo(ToolExecutionRecord.State.SETTLED);
        assertThat(journal.jdbc.queryForObject("SELECT producer_phase FROM ma_output_capture", String.class))
                .isEqualTo("FINISHED");
        assertThat(journal.jdbc.queryForObject("SELECT COUNT(*) FROM ma_output_capture"
                + " WHERE state = 'OPEN' AND expires_at > (" + ManagedSchemaTime.SQL_NOW + ")",
                Integer.class)).isEqualTo(1);
    }

    private static ToolPublicationDataStore data(PublicationJournalFixture journal, FileBucket bucket) {
        return new ToolPublicationDataStore(journal.jdbc, journal.manager, journal.store, journal.sessions, bucket,
                Duration.ofMinutes(2), Duration.ofSeconds(30),
                new ToolPublicationDataStore.VerificationBudget(16 * 1024 * 1024, Duration.ofMinutes(25)));
    }

    private static DataSource source(String stage) {
        String url = System.getProperty("qwen.csi." + stage + ".url");
        assertThat(url).startsWith("jdbc:mysql://127.0.0.1:");
        return new DriverManagerDataSource(url, "root", "qwen-local-disposable-fixture");
    }

    private static Path root() {
        return Path.of(System.getProperty("qwen.csi.root"));
    }

    private static void write(String file, ObjectNode value) throws IOException {
        JSON.writerWithDefaultPrettyPrinter().writeValue(root().resolve(file).toFile(), value);
    }

    private static String sha256(byte[] bytes) {
        return ToolPublicationContract.sha256(bytes);
    }

    private static String serializerDigest() throws IOException {
        try (InputStream bytes = ToolPublicationDataStore.class.getResourceAsStream("ToolPublicationDataStore.class")) {
            assertThat(bytes).isNotNull();
            return sha256(bytes.readAllBytes());
        }
    }

    private static ObjectNode identity(PublicationJournalFixture journal, FileBucket bucket) throws IOException {
        return JSON.createObjectNode()
                .put("pid", ProcessHandle.current().pid())
                .put("runtimeStart", ProcessHandle.current().info().startInstant().orElseThrow().toString())
                .put("serializerSha256", serializerDigest())
                .put("database", journal.jdbc.queryForObject("SELECT DATABASE()", String.class))
                .put("snapshotSha256", catalogDigest(journal))
                .put("objectsSha256", bucket.digest())
                .put("objectReads", bucket.reads)
                .put("objectPuts", bucket.puts);
    }

    private static void assertUnchanged(PublicationJournalFixture journal, FileBucket bucket, JsonNode prior)
            throws IOException {
        assertThat(journal.jdbc.queryForObject("SELECT DATABASE()", String.class))
                .isEqualTo(prior.path("database").asText());
        assertThat(catalogDigest(journal)).isEqualTo(prior.path("snapshotSha256").asText());
        assertThat(bucket.digest()).isEqualTo(prior.path("objectsSha256").asText());
        assertThat(bucket.reads).isZero();
        assertThat(bucket.puts).isZero();
    }

    private static String catalogDigest(PublicationJournalFixture journal) throws IOException {
        var tables = new TreeMap<String, List<String>>();
        for (String table : List.of("ma_operation", "ma_resource", "ma_resource_ref", "ma_output_capture",
                "ma_session_head", "ma_tool_execution", "ma_runtime_binding", "ma_runtime_session",
                "ma_storage", "ma_storage_owner", "ma_tenant_guard")) {
            var rows = new ArrayList<String>();
            for (var row : journal.jdbc.queryForList("SELECT * FROM " + table)) {
                rows.add(JSON.writeValueAsString(new TreeMap<>(row)));
            }
            rows.sort(String::compareTo);
            tables.put(table, rows);
        }
        return sha256(JSON.writeValueAsBytes(tables));
    }

    private static final class FileBucket implements ToolPublicationObjectStore {
        private final Path directory;
        private int reads;
        private int puts;

        private FileBucket(Path directory) throws IOException {
            this.directory = Files.createDirectories(directory);
        }

        @Override
        public void putIfAbsent(String key, byte[] bytes) {
            puts++;
            try {
                Files.write(path(key), bytes, StandardOpenOption.CREATE_NEW);
            } catch (IOException error) {
                throw new UncheckedIOException(error);
            }
        }

        @Override
        public InputStream open(String key) {
            reads++;
            try {
                return Files.newInputStream(path(key));
            } catch (IOException error) {
                throw new UncheckedIOException(error);
            }
        }

        @Override
        public InputStream openRange(String key, long offset, long length, Runnable guard) {
            guard.run();
            try (InputStream input = open(key)) {
                input.skipNBytes(offset);
                return new ByteArrayInputStream(input.readNBytes(Math.toIntExact(length)));
            } catch (IOException error) {
                throw new UncheckedIOException(error);
            }
        }

        @Override
        public void validateConfiguration() {}

        private Path path(String key) {
            return directory.resolve(sha256(key.getBytes(StandardCharsets.UTF_8)));
        }

        private String digest() throws IOException {
            var objects = new TreeMap<String, String>();
            try (var paths = Files.list(directory)) {
                for (Path object : paths.toList()) {
                    objects.put(object.getFileName().toString(), sha256(Files.readAllBytes(object)));
                }
            }
            return sha256(JSON.writeValueAsBytes(objects));
        }
    }
}
