import { createLifecyclePlaceholder, type LifecycleComponent } from "@/core/shared";

export const createTurnsFeaturePlaceholder = (): LifecycleComponent =>
  createLifecyclePlaceholder("feature.turns");
