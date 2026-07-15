import { createRendezvousServer } from "./server.mjs";

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
