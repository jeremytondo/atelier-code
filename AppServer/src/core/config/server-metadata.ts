export interface HealthcheckReport {
  status: "ok";
  server: "ateliercode-app-server";
  version: string;
}

export const APP_SERVER_NAME = "ateliercode-app-server";
export const SERVER_VERSION = "0.1.0";

export function buildHealthcheckReport(): HealthcheckReport {
  return {
    status: "ok",
    server: APP_SERVER_NAME,
    version: SERVER_VERSION,
  };
}
