import "./core/config/env";

import {
  SERVER_VERSION,
  buildHealthcheckReport,
  startServer,
} from "./app/server";

if (import.meta.main) {
  await main();
}

async function main(): Promise<void> {
  const argumentsList = process.argv.slice(2);

  if (argumentsList.includes("--healthcheck")) {
    process.stdout.write(
      `${JSON.stringify(buildHealthcheckReport(), null, 2)}\n`,
    );
    return;
  }

  const server = await startServer();
  process.stdout.write(
    `${JSON.stringify({
      recordType: "app-server.startup",
      host: server.host,
      port: server.port,
      version: SERVER_VERSION,
      pid: process.pid,
    })}\n`,
  );

  process.on("SIGINT", () => {
    server.stop();
    process.exit(0);
  });
}
