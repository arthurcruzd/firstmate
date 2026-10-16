import os, pathlib, subprocess, tempfile, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/fm/.no-mistakes/evidence/01M51EHJWSESFXEWMPFWV70T09')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.tz-live-',dir=root))
log=[]
def run(cmd,env,input=None):
 p=subprocess.run(cmd,env=env,input=input,text=True,capture_output=True)
 log.append('$ '+ ' '.join(map(str,cmd))+' TZ='+env.get('TZ','')+'\n'+p.stdout+p.stderr)
 assert p.returncode==0,(cmd,p.returncode,p.stderr)
 return p.stdout
try:
 for writer,reader in [('BRT3','UTC0'),('UTC0','BRT3')]:
  home=lab/(writer+'-'+reader)
  for d in ['state','data','config','projects/approved']:(home/d).mkdir(parents=True,exist_ok=True)
  (home/'config/supervision-host-off').touch()
  env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
  env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'),TZ=writer)
  state=home/'state'; status=state/'mate.status'
  status.write_text('needs-decision [key=old]: choose old target\nnote: first presentation\n')
  birth=run(['stat','-c','%W|%w',str(status)],env)
  other=run(['stat','-c','%W|%w',str(status)],dict(env,TZ=reader))
  assert not birth.startswith('0|') and birth!=other
  first=run(['bash',str(root/'bin/fm-wake-drain.sh')],env)
  assert 'first presentation' in first and 'choose old target' in first
  cursor=(state/'.status-presentation-cursor').read_text();log.append('Cursor after first presentation:\n'+cursor)
  with status.open('a') as f:f.write('resolved [key=old]: chosen\nnote: new across timezone\n')
  second=run(['bash',str(root/'bin/fm-wake-drain.sh')],dict(env,TZ=reader))
  assert 'first presentation' not in second and 'new across timezone' in second and 'OPEN DECISIONS' not in second
  third=run(['bash',str(root/'bin/fm-wake-drain.sh')],env)
  assert 'new across timezone' not in third and 'OPEN DECISIONS' not in third
  # Real CLI consumes shell-written cursor, with an old open hold outside the new span.
  with status.open('a') as f:f.write('needs-decision [key=held]: older held call\nnote: held context presented\n')
  run(['bash',str(root/'bin/fm-wake-drain.sh')],env)
  (state/'mate.meta').write_text(f'project={home}/projects/approved\nwindow=mate-window\nkind=secondmate\n')
  with status.open('a') as f:f.write('done: routine merged result\n')
  (state/'.wake-queue').write_text('1\t1\tsignal\tmate.status\tsignal: mate.status\n')
  for command in ['scope','offer']:
   out=run(['node',str(root/'bin/fm-branch-dispatch.mjs'),command],dict(env,TZ=reader), 'signal: mate.status\n')
   assert 'rows=1\n' in out and (command!='offer' or 'eligible=1' in out)
  with status.open('a') as f:f.write('blocked: new forge outage\n')
  for command in ['scope','offer']:
   out=run(['node',str(root/'bin/fm-branch-dispatch.mjs'),command],dict(env,TZ=reader), 'signal: mate.status\n')
   assert 'rows=\n' in out and (command!='offer' or 'eligible=0' in out)
  # Remove queued event, replace file while keeping old inode allocated.
  (state/'.wake-queue').unlink();status.rename(state/'old.log')
  status.write_text('needs-decision [key=replacement]: new file decision\nnote: new file note\n')
  out=run(['bash',str(root/'bin/fm-wake-drain.sh')],dict(env,TZ=reader))
  assert 'new file decision' in out and 'new file note' in out and 'older held call' not in out
  log.append(f'ASSERTIONS PASSED: {writer} -> {reader}: no replay, resolution, append, routing, blocker, replacement.\n')
finally:
 shutil.rmtree(lab)
 (evidence/'timezone-live-transcript.txt').write_text('\n'.join(log))
