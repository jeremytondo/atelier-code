import type { AgentRequestId } from "@/agents/contracts";
import type { RequestId } from "@/core/protocol";

export type CreateAgentRequestIdOptions = Readonly<{
  connectionId: string;
  method: string;
  requestId: RequestId;
}>;

export const createAgentRequestId = ({
  connectionId,
  method,
  requestId,
}: CreateAgentRequestIdOptions): AgentRequestId =>
  `atelier-appserver:${method}:${connectionId}:${String(requestId)}`;
