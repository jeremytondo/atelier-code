export type LifecycleComponent = Readonly<{
  name: string;
  start: () => Promise<void>;
  stop: (reason: string) => Promise<void>;
}>;

export const createLifecyclePlaceholder = (name: string): LifecycleComponent =>
  Object.freeze({
    name,
    start: async () => {},
    stop: async () => {},
  });
