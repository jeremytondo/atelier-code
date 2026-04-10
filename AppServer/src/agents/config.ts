import { type Static, Type } from "@sinclair/typebox";

export const CodexAgentConfigSchema = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    provider: Type.Literal("codex"),
    executablePath: Type.Optional(Type.String({ minLength: 1 })),
    environment: Type.Optional(Type.Record(Type.String({ minLength: 1 }), Type.String())),
  },
  { additionalProperties: false },
);

export const EnabledAgentConfigSchema = Type.Union([CodexAgentConfigSchema]);

export const AgentsConfigSchema = Type.Object(
  {
    defaultAgent: Type.String({ minLength: 1 }),
    enabled: Type.Array(EnabledAgentConfigSchema, { minItems: 1 }),
  },
  { additionalProperties: false },
);

export type CodexAgentConfig = Static<typeof CodexAgentConfigSchema>;
export type EnabledAgentConfig = Static<typeof EnabledAgentConfigSchema>;
export type AgentsConfig = Static<typeof AgentsConfigSchema>;

export const validateAgentsConfig = (config: AgentsConfig): readonly string[] => {
  const issues: string[] = [];
  const seenAgentIds = new Set<string>();

  for (const definition of config.enabled) {
    if (seenAgentIds.has(definition.id)) {
      issues.push(`configuration file /agents/enabled: duplicate agent id "${definition.id}"`);
      continue;
    }

    seenAgentIds.add(definition.id);
  }

  if (!seenAgentIds.has(config.defaultAgent)) {
    issues.push(
      `configuration file /agents/defaultAgent: default agent "${config.defaultAgent}" is not enabled`,
    );
  }

  return Object.freeze(issues);
};
