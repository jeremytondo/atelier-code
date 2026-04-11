import { createLifecyclePlaceholder, type LifecycleComponent } from "@/core/shared";

export const createTurnsModulePlaceholder = (): LifecycleComponent =>
  createLifecyclePlaceholder("module.turns");
