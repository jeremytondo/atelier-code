import { type Static, Type } from "@sinclair/typebox";

export const ModelReasoningEffortSchema = Type.Union([
  Type.Literal("none"),
  Type.Literal("minimal"),
  Type.Literal("low"),
  Type.Literal("medium"),
  Type.Literal("high"),
  Type.Literal("xhigh"),
]);
export type ModelReasoningEffort = Static<typeof ModelReasoningEffortSchema>;

export const ModelReasoningEffortSummarySchema = Type.Object(
  {
    reasoningEffort: ModelReasoningEffortSchema,
    description: Type.Optional(Type.String({ minLength: 1 })),
  },
  { additionalProperties: false },
);
export type ModelReasoningEffortSummary = Static<typeof ModelReasoningEffortSummarySchema>;

export const ModelSummarySchema = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    model: Type.String({ minLength: 1 }),
    displayName: Type.String({ minLength: 1 }),
    hidden: Type.Boolean(),
    defaultReasoningEffort: Type.Optional(ModelReasoningEffortSchema),
    supportedReasoningEfforts: Type.Array(ModelReasoningEffortSummarySchema),
    inputModalities: Type.Optional(Type.Array(Type.String({ minLength: 1 }))),
    supportsPersonality: Type.Optional(Type.Boolean()),
    isDefault: Type.Boolean(),
  },
  { additionalProperties: false },
);
export type ModelSummary = Static<typeof ModelSummarySchema>;

export const ModelListParamsSchema = Type.Object(
  {
    limit: Type.Optional(Type.Integer({ minimum: 0 })),
    includeHidden: Type.Optional(Type.Boolean()),
  },
  { additionalProperties: false },
);
export type ModelListParams = Static<typeof ModelListParamsSchema>;

export const ModelListResultSchema = Type.Object(
  {
    models: Type.Array(ModelSummarySchema),
    nextCursor: Type.Union([Type.String({ minLength: 1 }), Type.Null()]),
  },
  { additionalProperties: false },
);
export type ModelListResult = Static<typeof ModelListResultSchema>;
