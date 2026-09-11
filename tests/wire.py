"""Exercise generated configs with real pinned clients against a loopback mock only.
PI_BIN and OMP_BIN point to executables; run after cargo build.
"""
import http.server,json,os,subprocess,tempfile,threading
from pathlib import Path
repo=Path(__file__).resolve().parents[1]
requests=[]
class Mock(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{"data":[{"id":"hotschmoe-dd"}]}')
 def do_POST(self):
  p=json.loads(self.rfile.read(int(self.headers['Content-Length'])));requests.append(p)
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  for delta,finish in [({'content':'OK'},None),({},'stop')]:
   self.wfile.write(('data: '+json.dumps({'id':'mock','object':'chat.completion.chunk','model':'hotschmoe-dd','created':1,'choices':[{'index':0,'delta':delta,'finish_reason':finish}]})+'\n\n').encode())
  self.wfile.write(b'data: [DONE]\n\n')
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Mock)
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
 with tempfile.TemporaryDirectory() as td:
  root=Path(td);(root/'input.json').write_text(json.dumps({'endpoint':'https://example.invalid','api_key':'dummy-key-for-mock'}));(root/'password').write_text('fixture-only-password')
  helper=repo/'target/debug/pi-omp-setup'
  def run(cmd,**kw):return subprocess.run(list(map(str,cmd)),check=True,capture_output=True,text=True,timeout=60,**kw)
  run([helper,'seal','--input',root/'input.json','--output',root/'bundle','--password-file',root/'password'])
  run([helper,'configure','--bundle',root/'bundle','--password-file',root/'password','--pi-dir',root/'pi','--omp-dir',root/'omp'])
  # Installer correctly requires HTTPS. Redirect only fixture configs to loopback.
  for path in [root/'pi/models.json', root/'omp/models.yml']:
   path.write_text(path.read_text().replace('https://example.invalid', f'http://127.0.0.1:{server.server_port}'))
  for client,var in [('pi','PI_BIN'),('omp','OMP_BIN')]:
   before=len(requests)
   env={**os.environ,'HOME':str(root),'PI_CODING_AGENT_DIR':str(root/client),'OMP_AGENT_DIR':str(root/client),'PI_OFFLINE':'1'}
   try:run([os.environ[var],'--mode','json','--provider','hotschmoe-local','--model','hotschmoe-dd','--no-extensions','--no-skills','-p','Reply OK.'],cwd=root,env=env)
   except subprocess.CalledProcessError as e:raise RuntimeError(client+': '+e.stderr[-2500:])
   assert len(requests)>before,client+' sent no requests'
   p=requests[before]
   assert p.get('max_tokens',p.get('max_completion_tokens'))==32768,(client,'output',p.keys())
   assert p.get('thinking_token_budget')==8192,(client,'budget',p.get('thinking_token_budget'))
   assert p.get('chat_template_kwargs',{}).get('reasoning_effort')=='medium',(client,'effort',p.get('chat_template_kwargs'))
   assert p['chat_template_kwargs'].get('preserve_thinking') is True
   print(client+': actual request verified: output32768/thinking8192/medium/preserved history')
finally:server.shutdown();server.server_close()
