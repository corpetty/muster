import subprocess, time, sys, os, threading, queue
HOST=sys.argv[1]; MODS=sys.argv[2]; LH=sys.argv[3]; DATA=sys.argv[4]; INST=sys.argv[5]
env=dict(os.environ); env["LOGOS_HOST_PATH"]=LH; env["MUSTER_DATA_DIR"]=DATA
p=subprocess.Popen([HOST,"--instance",INST,"--modules-dir",MODS,"--persistence",DATA],
                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
q=queue.Queue()
def rd():
    for line in p.stdout: q.put(line.rstrip("\n"))
threading.Thread(target=rd, daemon=True).start()
def send(s):
    p.stdin.write(s+"\n"); p.stdin.flush()
def wait(sec=8):
    try: return q.get(timeout=sec)
    except queue.Empty: return "(no reply)"
time.sleep(6)   # let it load + acquire
send("muster_module\thealth");           print("health   ->", wait())
send("muster_module\tidentity");         print("identity ->", wait())
send("muster_module\tdescribe");         print("describe ->", wait()[:80])
send("quit"); time.sleep(0.5); p.terminate()
