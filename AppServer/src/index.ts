import { FakeAgentAdapter } from "./agent-adapters/fake-agent-adapter";
import { AppServerService } from "./server/app-server-service";
import { CounterIdGenerator } from "./server/counter-id-generator";
import {
  SERVER_VERSION,
  buildHealthcheckReport,
} from "./server/server-metadata";
import { NodeWorkspacePathAccess } from "./server/workspace-paths";
import { InMemoryAppServerStore } from "./store/in-memory-store";
import {
  type AppServerHandle,
  startWebSocketServer,
} from "./transport/websocket-server";

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

  const server = await createAppServer();
  process.stdout.write(
    `${JSON.stringify({
      recordType: "app-server.startup",
      host: server.host,
      port: server.port,
      version: SERVER_VERSION,
      pid: process.pid,
    })}\n`,
  );
}

export async function createAppServer(port = 0): Promise<AppServerHandle> {
  return startWebSocketServer({
    port,
    service: new AppServerService(
      new InMemoryAppServerStore(),
      new FakeAgentAdapter(),
      new NodeWorkspacePathAccess(),
      new CounterIdGenerator(),
      {
        now: () => Math.floor(Date.now() / 1000),
      },
    ),
  });
}
