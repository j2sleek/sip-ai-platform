/**
 * Backend factory: chooses the call control backend from configuration.
 */

import type { AriConfig, CallBackendKind } from "../config.js";
import { AriBackend } from "./ari.js";
import type { BackendDeps, CallBackend } from "./backend.js";
import { SimulatedBackend } from "./simulated.js";

export function createBackend(
  kind: CallBackendKind,
  ari: AriConfig,
  deps: BackendDeps,
): CallBackend {
  switch (kind) {
    case "ari":
      return new AriBackend(ari, deps);
    case "simulated":
    default:
      return new SimulatedBackend(deps);
  }
}

export type { CallBackend };
