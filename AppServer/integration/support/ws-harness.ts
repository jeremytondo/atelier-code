import WebSocket from "ws";

import type {
  JsonRpcErrorResponse,
  JsonRpcNotification,
  JsonRpcRequest,
  JsonRpcSuccessResponse,
  RequestId,
} from "../../src/core/protocol/types";

export class WebSocketHarness {
  readonly socket: WebSocket;
  private readonly messageQueue: unknown[] = [];
  private readonly resolvers: Array<(message: unknown) => void> = [];

  constructor(url: string) {
    this.socket = new WebSocket(url);
    this.socket.on("message", (message: WebSocket.RawData) => {
      const parsed = JSON.parse(message.toString()) as unknown;
      const resolver = this.resolvers.shift();
      if (resolver) {
        resolver(parsed);
      } else {
        this.messageQueue.push(parsed);
      }
    });
  }

  async waitForOpen(): Promise<void> {
    if (this.socket.readyState === WebSocket.OPEN) {
      return;
    }

    await new Promise<void>((resolve, reject) => {
      this.socket.once("open", () => resolve());
      this.socket.once("error", (error: Error) => reject(error));
    });
  }

  async sendRequest(
    request: JsonRpcRequest,
  ): Promise<JsonRpcSuccessResponse | JsonRpcErrorResponse> {
    this.sendRaw(JSON.stringify(request));
    const response = await this.nextMatchingMessage(
      (message): message is JsonRpcSuccessResponse | JsonRpcErrorResponse =>
        typeof message === "object" &&
        message !== null &&
        "id" in message &&
        (message.id === request.id || message.id === null),
    );

    return response;
  }

  sendRaw(rawMessage: string): void {
    this.socket.send(rawMessage);
  }

  async nextNotification(): Promise<JsonRpcNotification> {
    return this.nextMatchingMessage(
      (message): message is JsonRpcNotification =>
        typeof message === "object" &&
        message !== null &&
        "method" in message &&
        !("id" in message),
    );
  }

  async nextResponse(): Promise<JsonRpcSuccessResponse | JsonRpcErrorResponse> {
    return this.nextMatchingMessage(
      (message): message is JsonRpcSuccessResponse | JsonRpcErrorResponse =>
        typeof message === "object" && message !== null && "id" in message,
    );
  }

  async close(): Promise<void> {
    if (this.socket.readyState === WebSocket.CLOSED) {
      return;
    }

    await new Promise<void>((resolve) => {
      this.socket.once("close", () => resolve());
      this.socket.close();
    });
  }

  async requestAndCollect(
    request: JsonRpcRequest,
    notificationCount: number,
  ): Promise<{
    response: JsonRpcSuccessResponse | JsonRpcErrorResponse;
    notifications: JsonRpcNotification[];
  }> {
    const response = await this.sendRequest(request);
    const notifications: JsonRpcNotification[] = [];
    for (let index = 0; index < notificationCount; index += 1) {
      notifications.push(await this.nextNotification());
    }

    return {
      response,
      notifications,
    };
  }

  buildRequest(
    id: RequestId,
    method: string,
    params?: unknown,
  ): JsonRpcRequest {
    return {
      id,
      method,
      params,
    };
  }

  private async nextMessage(): Promise<unknown> {
    if (this.messageQueue.length > 0) {
      return this.messageQueue.shift();
    }

    return new Promise<unknown>((resolve) => {
      this.resolvers.push(resolve);
    });
  }

  private async nextMatchingMessage<TMessage>(
    predicate: (message: unknown) => message is TMessage,
  ): Promise<TMessage> {
    const deferred: unknown[] = [];

    while (true) {
      const message = await this.nextMessage();
      if (predicate(message)) {
        for (const deferredMessage of deferred) {
          this.messageQueue.push(deferredMessage);
        }
        return message;
      }

      deferred.push(message);
    }
  }
}
