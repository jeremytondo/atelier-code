import type { CodexTransport, CodexTransportRequest } from "./codex-transport";

export class CodexClient {
  constructor(private readonly transport: CodexTransport) {}

  async connect(): Promise<void> {
    await this.transport.connect();
  }

  async disconnect(): Promise<void> {
    await this.transport.disconnect();
  }

  async send(request: CodexTransportRequest): Promise<void> {
    await this.transport.send(request);
  }
}
