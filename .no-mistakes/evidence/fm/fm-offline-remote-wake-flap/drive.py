import os, pathlib, subprocess, tempfile, time, shutil, sys
root=pathlib.Path.cwd()
lab=pathlib.Path(tempfile.mkdtemp(prefix='.outage-live-',dir=root))
cli=root/(sys.argv[1] if len(sys.argv)>1 else 'bin/fm-procevent.sh')
env=os.environ.copy()
for k in list(env):
    if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k in ('FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID'): env.pop(k)
env.update(FM_HOME=str(lab),FM_PROCEVENT_CLAIM_ROOT=str(lab/'claims'))
(lab/'state').mkdir(mode=0o700)
id='outage-live'
reg=lab/'state/procevent'/f'{id}.source'
marker=reg.parent/f'.{id}.launch-failed'
claim=lab/'claims'/f'{id}.claim'
trigger=lab/'release'
source=lab/'transport.sh'
source.write_text('''#!/bin/sh
while [ ! -e "$1" ]; do sleep 0.1; done
ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=1 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null -p 1 127.0.0.1 true
rc=$?
printf '%s\\n' "$rc" > "$2"
exit "$rc"
''')
source.chmod(0o700)
def run(*args,window=2):
    e=env.copy(); e['FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS']=str(window)
    p=subprocess.run([str(cli),*args],env=e,text=True,capture_output=True,timeout=65)
    print('$ fm-procevent.sh '+' '.join(args),flush=True)
    print(f'exit={p.returncode} {p.stdout.strip()} {p.stderr.strip()}',flush=True)
    return p

def register(adapter='lavish',argv=None):
    p=run('register',adapter,id,'--',*(argv or [str(source),str(trigger),str(lab/'ssh-exit')]))
    assert p.returncode==0
    print('registration device:inode =',f'{reg.stat().st_dev}:{reg.stat().st_ino}',flush=True)

def damage():
    text=reg.read_text(); reg.write_text(text.split('argv:\n')[0]+'argv:\n')
    print('Fault injection: remove registered argv in place; launches cannot claim.',flush=True)

def wait(predicate,label):
    deadline=time.monotonic()+35
    while time.monotonic()<deadline:
        if predicate(): return
        time.sleep(.1)
    raise AssertionError('Timed out: '+label)

def wakes():
    q=lab/'state/.wake-queue'
    rows=[r for r in q.read_text().splitlines() if f'procevent:{id}:launch-failed:' in r] if q.exists() else []
    print('launch-failed wake keys:',[r.split('\t')[3] for r in rows],flush=True)
    return rows

def fail_launch(n):
    p=run('reconcile'); assert p.returncode!=0 and 'failed=1' in p.stdout
    assert len(wakes())==n

def snapshot(label):
    print('\nSTATE:',label,'marker=',marker.read_text().strip() if marker.exists() else 'absent',flush=True)
    run('list'); wakes()

try:
    register(); damage(); fail_launch(1); fail_launch(1)
    first=marker.read_text(); inode=reg.stat().st_ino
    register(); assert reg.stat().st_ino!=inode
    p=run('reconcile',window=30); assert 'failed=0' in p.stdout
    wait(claim.exists,'claimed'); run('reconcile')
    snapshot('claimed and blocked; outage must remain open')
    assert marker.exists() and marker.read_text()==first
    trigger.touch(); wait(lambda:not claim.exists(),'failed read released')
    assert (lab/'ssh-exit').read_text().strip()=='255'
    assert not list((lab/'state/procevent-inbox').glob('*.result'))
    damage(); fail_launch(1); register(); damage(); fail_launch(1)
    snapshot('continuous outage across re-registrations and SSH failure')
    print('PASS: one continuous outage, retries unchanged, one announcement',flush=True)

    register(argv=['/usr/bin/printf','recovered payload'])
    run('reconcile',window=30)
    wait(lambda:bool(list((lab/'state/procevent-inbox').glob('*.result'))) and not claim.exists(),'captured recovery')
    assert not marker.exists() and reg.exists()
    for f in (lab/'state/procevent-inbox').glob('*.result'): print('CAPTURE:',f.read_text(),flush=True)
    damage(); fail_launch(2)
    snapshot('new outage after durable capture')
    print('PASS: captured recovery enables a second distinct announcement',flush=True)

    empty=lab/'empty.sh'; roundfile=lab/'round'
    empty.write_text('''#!/bin/sh
if [ ! -e "$1" ]; then touch "$1"; exit 75; fi
touch "$2"
while [ ! -e "$3" ]; do sleep 0.1; done
exit 255
'''); empty.chmod(0o700)
    register('remote-reply',[str(empty),str(roundfile),str(lab/'relistened'),str(lab/'finish-empty')])
    run('reconcile',window=30)
    wait(lambda:(lab/'relistened').exists(),'second clean-empty poll')
    assert not marker.exists() and claim.exists()
    snapshot('clean empty window relistens and clears episode')
    (lab/'finish-empty').touch(); wait(lambda:not claim.exists(),'empty runner exited')
    damage(); fail_launch(3)
    print('PASS: clean empty relisten enables a new announcement',flush=True)

    run('retire',id); assert not marker.exists() and not reg.exists() and not claim.exists()
    register(); damage(); fail_launch(4)
    snapshot('retire then re-arm starts fresh episode')
    print('PASS: retirement clears outage marker',flush=True)
    print('FINAL WAKE QUEUE:\n'+(lab/'state/.wake-queue').read_text(),flush=True)
finally:
    run('retire',id)
    shutil.rmtree(lab)
    print('Disposable home removed.',flush=True)
