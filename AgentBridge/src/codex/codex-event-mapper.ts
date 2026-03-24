export interface BridgeEventEnvelope {
  type: string;
  payload: Record<string, unknown>;
}

export interface CodexEventMapper {
  map(notification: unknown): BridgeEventEnvelope[];
}

export class UnimplementedCodexEventMapper implements CodexEventMapper {
  map(_notification: unknown): BridgeEventEnvelope[] {
    throw new Error("Codex event mapping is not implemented in runtime foundation step 1.");
  }
}
