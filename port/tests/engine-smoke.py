"""Run an isolated server with disposable data and verify session persistence."""
import base64, json, os, pathlib, secrets, shutil, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request

node, engine, icu = sys.argv[1:4]
root = pathlib.Path(tempfile.mkdtemp(prefix='opencode-v2-smoke-'))
password = secrets.token_urlsafe(32)
env = os.environ.copy()
for key in list(env):
    if key.startswith('OPENCODE_'):
        del env[key]
env.update(HOME=str(root), XDG_CONFIG_HOME=str(root/'config'), XDG_DATA_HOME=str(root/'data'),
           XDG_STATE_HOME=str(root/'state'), XDG_CACHE_HOME=str(root/'cache'), NODE_ICU_DATA=icu,
           OPENCODE_PASSWORD=password, OPENCODE_DISABLE_MODELS_FETCH='1',
           OPENCODE_DISABLE_CLAUDE_CODE='1', OPENCODE_DISABLE_PROJECT_CONFIG='1')
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0)); port=sock.getsockname()[1]
url='http://127.0.0.1:'+str(port)
auth='Basic '+base64.b64encode(('opencode:'+password).encode()).decode()
config=root/'config'/'opencode'
config.mkdir(parents=True,mode=0o700)
(config/'service.json').write_text(json.dumps({'password':password}))
os.chmod(config/'service.json',0o600)
log=(root/'server.log').open('w+')
os.chmod(root/'server.log',0o600)
process=None

def request(path, data=None, authenticated=True):
    headers={}
    if authenticated: headers['Authorization']=auth
    if data is not None: headers['Content-Type']='application/json'
    req=urllib.request.Request(url+path,headers=headers,data=None if data is None else json.dumps(data).encode())
    with urllib.request.urlopen(req,timeout=5) as response: return response.status,response.read()

def start():
    global process
    process=subprocess.Popen([node,'--predictable','--single-threaded','--disable-wasm-trap-handler',
      '--max-old-space-size=512',engine,'serve','--service','--hostname','127.0.0.1','--port',str(port)],
      cwd=root,env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
    deadline=time.monotonic()+90
    while time.monotonic()<deadline:
        if process.poll() is not None: raise RuntimeError('server exited: '+str(process.returncode))
        try:
            status,body=request('/api/info')
            if status==200:return json.loads(body)
        except (OSError, urllib.error.URLError): time.sleep(.5)
    raise RuntimeError('server did not become ready')

def stop():
    global process
    if process and process.poll() is None:
        process.terminate()
        try:process.wait(timeout=15)
        except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
    process=None

try:
    info=start()
    if info['version']!='2.2.0': raise RuntimeError('unexpected server version')
    try: request('/api/info',authenticated=False);raise RuntimeError('unauthenticated request succeeded')
    except urllib.error.HTTPError as e:
        if e.code != 401:raise
    status,body=request('/api/session',{'title':'Disposable port smoke test','location':{'directory':str(root)}})
    session=json.loads(body)['data']['id']
    stop();start()
    status,body=request('/api/session/'+session)
    assert json.loads(body)['data']['id']==session
    print('Isolated authenticated server, session creation and restart persistence passed')
finally:
    stop();log.close()
    # Log contains only disposable data, but may include random authentication data.
    shutil.rmtree(root)
