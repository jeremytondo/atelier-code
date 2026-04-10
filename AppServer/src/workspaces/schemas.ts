import { type Static, Type } from "@sinclair/typebox";

export const WorkspaceSchema = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    workspacePath: Type.String({ minLength: 1 }),
    createdAt: Type.String({ minLength: 1 }),
    lastOpenedAt: Type.String({ minLength: 1 }),
  },
  { additionalProperties: false },
);
export type Workspace = Static<typeof WorkspaceSchema>;

export const WorkspaceOpenParamsSchema = Type.Object(
  {
    workspacePath: Type.String({ minLength: 1 }),
  },
  { additionalProperties: false },
);
export type WorkspaceOpenParams = Static<typeof WorkspaceOpenParamsSchema>;

export const WorkspaceOpenResultSchema = Type.Object(
  {
    workspace: WorkspaceSchema,
  },
  { additionalProperties: false },
);
export type WorkspaceOpenResult = Static<typeof WorkspaceOpenResultSchema>;
