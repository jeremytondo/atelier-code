export interface CodexTransportRequest {
  id: string;
  method: string;
  params?: Record<string, unknown>;
}

export interface CodexTransportNotification {
  method: string;
  params?: Record<string, unknown>;
}

export interface CodexTransport {
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  send(request: CodexTransportRequest): Promise<void>;
}
