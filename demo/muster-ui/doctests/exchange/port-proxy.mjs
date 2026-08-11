// Expose an already-listening local TCP port on another one: accept
// connections on LISTEN_PORT and pipe each to 127.0.0.1:TARGET_PORT.
//
// Used by run-exchange-show.sh to gate the doc-test's capture port: the app
// binds its QML inspector the moment it starts, so the only way to make "the
// port is open" mean "the exchange is finished" is to run the exchange on a
// private inspector port and open the capture port afterwards, as this proxy
// onto the live window.
//
// Env:
//   LISTEN_PORT   port to listen on
//   TARGET_PORT   local port to forward to
import net from "node:net";

const listenPort = parseInt(process.env.LISTEN_PORT, 10);
const targetPort = parseInt(process.env.TARGET_PORT, 10);
if (!listenPort || !targetPort) {
  console.error("port-proxy: LISTEN_PORT and TARGET_PORT are required");
  process.exit(1);
}

const server = net.createServer((client) => {
  const upstream = net.createConnection({ host: "127.0.0.1", port: targetPort });
  client.pipe(upstream);
  upstream.pipe(client);
  const drop = () => { client.destroy(); upstream.destroy(); };
  client.on("error", drop);
  upstream.on("error", drop);
  client.on("close", drop);
  upstream.on("close", drop);
});
server.listen(listenPort, "127.0.0.1", () => {
  console.log(`port-proxy: ${listenPort} -> ${targetPort}`);
});
