import type { BridgeEvent } from "../protocol/types";

export interface CodexEventMapper {
  map(notification: unknown): BridgeEvent[];
}

export class UnimplementedCodexEventMapper implements CodexEventMapper {
  map(_notification: unknown): BridgeEvent[] {
    throw new Error("Codex event mapping is not implemented in runtime foundation step 1.");
  }
}
