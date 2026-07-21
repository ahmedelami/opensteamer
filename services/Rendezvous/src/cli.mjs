import { createRendezvousServer } from "./server.mjs";

// The CLI owns process signals while the reusable server module owns sockets and cleanup.
const rendezvous = createRendezvousServer();
await rendezvous.start();

let stopping = false;
const stop = async () => {
  if (stopping) return;
  stopping = true;
  await rendezvous.stop();
  process.exitCode = 0;
};

process.once("SIGINT", stop);
process.once("SIGTERM", stop);
