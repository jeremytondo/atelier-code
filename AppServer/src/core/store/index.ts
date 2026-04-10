import { createLifecyclePlaceholder, type LifecycleComponent } from "@/core/shared";

export const createStoreBootstrapPlaceholder = (): LifecycleComponent =>
  createLifecyclePlaceholder("core.store");
