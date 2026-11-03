import hashlib,json,os,pathlib,subprocess,sys,datetime
root=pathlib.Path.cwd();temp=pathlib.Path(os.environ['RUNNER_TEMP']);out=temp/'qwen-c6-results';out.mkdir(exist_ok=True)
fixture=temp/'qwen-c6-fixture.tsx';patch=temp/'qwen-c6-probe.patch';test_path='packages/cli/src/ui/hooks/use-llm-stream.test.tsx'
assert hashlib.sha256(fixture.read_bytes()).hexdigest()=='7345c0d47eac8754c651c24befbdfb4411ec58ac3fef68554e35422e333b9cbf'
assert hashlib.sha256(patch.read_bytes()).hexdigest()=='f852a4107f1065cb000fa2166f02cfd4c7e2e0904318058a20463a420478d8db'
production=['packages/cli/src/ui/hooks/use-llm-stream.ts','packages/cli/src/ui/hooks/shellCommandProcessor.ts']
refs={'base':'35aa4b76ae10a458632d23c9b0052af5a31b3885','head':'0f2c7d7d8a0830092a710e6cfc4cf247757265d8'}
def command(args,**kw):return subprocess.run(args,check=False,text=True,**kw)
def read(args):return subprocess.check_output(args,text=True).strip()
def hashes(paths):return {p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths}
dependency_paths=['package.json','pnpm-lock.yaml','packages/cli/package.json','packages/core/package.json']
for p in dependency_paths:
 a=subprocess.check_output(['git','show',refs['base']+':'+p]);b=subprocess.check_output(['git','show',refs['head']+':'+p]);assert a==b,('DEPENDENCY_MISMATCH',p)
results={}
for label,ref in refs.items():
 summary={'label':label,'source_sha':ref,'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'product_test_executed':False}
 try:
  if command(['git','switch','--detach',ref]).returncode:raise RuntimeError('CHECKOUT_FAILED')
  assert read(['git','rev-parse','HEAD'])==ref
  summary['dependency_sha256']=hashes(dependency_paths);summary['production_sha256_before']=hashes(production)
  with (out/(label+'-build.log')).open('w') as log:
   build=command(['npm','run','build'],stdout=log,stderr=subprocess.STDOUT)
  summary['build_exit_code']=build.returncode
  if build.returncode:summary['classification']='BUILD_FAILED_INCONCLUSIVE';continue
  assert read(['git','diff','--name-only'])=='','unexpected tracked modifications from build'
  (root/test_path).write_bytes(fixture.read_bytes())
  check=command(['git','apply','--check',str(patch)],capture_output=True);assert check.returncode==0,check.stderr
  applied=command(['git','apply',str(patch)],capture_output=True);assert applied.returncode==0,applied.stderr
  summary['test_fixture_sha256']=hashes([test_path])[test_path]
  args=['corepack','pnpm','exec','vitest','run','src/ui/hooks/use-llm-stream.test.tsx','-t','independent-13449-C6','--maxWorkers=1','--no-file-parallelism','--coverage.enabled=false','--reporter=default','--reporter=json','--outputFile='+str(out/(label+'-vitest.json'))]
  summary['test_command']=args;env=dict(os.environ);env['QWEN_C6_SOURCE_LABEL']=label
  with (out/(label+'-test.log')).open('w') as log:
   run=command(args,cwd=root/'packages/cli',env=env,stdout=log,stderr=subprocess.STDOUT)
  summary['test_exit_code']=run.returncode;summary['production_sha256_after']=hashes(production)
  assert summary['production_sha256_after']==summary['production_sha256_before'],'production changed during probe'
  summary['observations']=[]
  for line in (out/(label+'-test.log')).read_text().splitlines():
   if 'PROBE-C6-INDEPENDENT ' in line:
    summary['observations'].append(json.loads(line.split('PROBE-C6-INDEPENDENT ',1)[1]))
  report=out/(label+'-vitest.json')
  if report.exists():
   r=json.loads(report.read_text());summary['test_counts']={k:r.get(k) for k in ['numTotalTests','numPassedTests','numFailedTests','numPendingTests','numRuntimeErrorTestSuites']}
   summary['selected_assertions']=[{'name':a.get('fullName'),'status':a.get('status'),'failureMessages':a.get('failureMessages')} for suite in r.get('testResults',[]) for a in suite.get('assertionResults',[]) if 'independent-13449-C6' in a.get('fullName','')]
  summary['product_test_executed']=len(summary['observations'])==1
  summary['classification']='OBSERVATION_COLLECTED' if summary['product_test_executed'] else 'NO_COMPLETE_OBSERVATION_INCONCLUSIVE'
 except Exception as e:
  summary['classification']='HARNESS_OR_ENVIRONMENT_ERROR_INCONCLUSIVE';summary['error']=str(e)
 finally:
  summary['finished_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();results[label]=summary
  (out/(label+'-summary.json')).write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary),flush=True)
  command(['git','restore','--source=HEAD','--',test_path])
comparison={'results':results,'probe_execution_is_not_terminal_or_real_provider_E2E':True,'both_complete':all(r.get('product_test_executed') for r in results.values()),'no_production_patch':True}
(out/'COMPARISON.json').write_text(json.dumps(comparison,indent=2)+'\n');print(json.dumps(comparison),flush=True)
# Invariant failures are measured data; fail the CI only if the comparison itself is inconclusive.
sys.exit(0 if comparison['both_complete'] else 1)
