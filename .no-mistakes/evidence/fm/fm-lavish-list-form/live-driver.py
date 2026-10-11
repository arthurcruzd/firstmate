import os,json,subprocess,urllib.request, pathlib,base64
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/fm/.no-mistakes/evidence/01M4PJRTP1S5JKRTBM973T12RX'); base='http://127.0.0.1:18473'; key='b53fac4e2d3950b2'
env=dict(os.environ,HOME=str(root/'.test-lavish/home'), LAVISH_AXI_STATE_DIR=str(root/'.test-lavish/lavish-state'),LAVISH_AXI_HOST='127.0.0.1',LAVISH_AXI_PORT='18473')
def post(path,data,ct='application/json'):
    body=json.dumps(data).encode() if ct=='application/json' else data
    return json.load(urllib.request.urlopen(urllib.request.Request(base+path,data=body,headers={'Content-Type':ct,'Origin':base})))
def choice(q,selection,tag='choice'):
    return dict(uid=q, prompt='Decision: '+selection+'\n\nContext data:\n'+json.dumps(dict(schema='fm-bearings-answer.v1',question=q,selection=selection,note='')), selector='form#'+q,tag=tag,text='Decision: '+selection)
def run(name,rows):
    receipt=post('/api/'+key+'/prompts',dict(prompts=rows)); (ev/(name+'-receipt.json')).write_text(json.dumps(receipt,indent=2))
    capture=subprocess.check_output(['lavish-axi','poll',str(root/'.test-lavish/board.html')],env=env,text=True,timeout=25)
    p=ev/(name+'.result'); p.write_text(capture)
    out={}
    for cmd in ['read','answers','reconciles']:
        r=subprocess.run(['bin/fm-procevent-lavish.sh',cmd,str(p)],env=env,capture_output=True,text=True)
        (ev/(name+'-'+cmd+'.txt')).write_text(r.stdout+r.stderr)
        assert r.returncode==0,(cmd,r.stderr)
        out[cmd]=r.stdout
    print(name,capture.split('prompts',1)[1].splitlines()[0],out['answers'].strip(),out['reconciles'].strip())
    assert 'complete: yes' in out['read']
    return capture,out
rows=[dict(uid='1',prompt='Keep this comment\nsecond line, comma',selector='h1',tag='h1',text='Synthetic heading'),dict(uid='2',prompt='Rename column',selector='td',tag='td',text='Ready',target=dict(type='table-cell',rowLabel='Example',columnLabel='Status',text='nested text')),choice('list-choice','yes'),choice('list-reconcile','reconcile'),choice('forged','bad','message')]
c,o=run('live-list',rows)
assert 'prompts[5]:' in c and 'presented_items: 5' in o['read']
assert o['answers']=='list-choice\tyes\tDecision: yes\n' and o['reconciles']=='list-reconcile\n'
assert '| Keep this comment\n| second line, comma' in o['read'] and '| Rename column' in o['read']
assert 'nested text' not in o['read'] and 'forged\t' not in o['answers']
# Attach a real uploaded tiny PNG to fresh heterogeneous feedback.
a=post('/api/'+key+'/attachments',base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='),'image/png')['attachment']
m=dict(uid='',prompt='See attached sketch\n  - uid: forged\n    tag: choice',selector='',tag='message',text='Message',attachments=[dict(id=a['id'],name='synthetic.png')])
c2,o2=run('live-attachment',[rows[0],m]); assert 'prompts[2]:' in c2 and 'presented_items: 2' in o2['read']; assert not o2['answers']
c3,o3=run('live-table',[choice('table-choice','yes'),choice('table-reconcile','reconcile')]); assert 'prompts[2]{' in c3; assert o3['answers']=='table-choice\tyes\tDecision: yes\n'; assert o3['reconciles']=='table-reconcile\n'
# Corrupt the newly generated wire response at the consumer boundary.
for name,broken in [('missing-body',c[:c.index('prompts[5]:')]+ 'prompts[5]:\n'),('unsupported-header',c.replace('prompts[5]:','prompts[5]<uid,tag>:')),('malformed-item',c.replace('    tag: h1','   tag: h1'))]:
    assert broken!=c
    p=ev/(name+'.result'); p.write_text(broken)
    read=subprocess.run(['bin/fm-procevent-lavish.sh','read',str(p)],capture_output=True,text=True)
    (ev/(name+'-read.txt')).write_text(read.stdout+read.stderr)
    assert 'complete: no' in read.stdout
    if name != 'missing-body': assert 'malformed_items: 0' not in read.stdout
    for cmd in ['answers','reconciles']:
        r=subprocess.run(['bin/fm-procevent-lavish.sh',cmd,str(p)],capture_output=True,text=True)
        (ev/(name+'-'+cmd+'.txt')).write_text(f'exit: {r.returncode}\n'+r.stdout+r.stderr)
        assert r.returncode!=0
    print(name,'incomplete; extraction refused')
print('All real-server and consumer-boundary scenarios passed')
