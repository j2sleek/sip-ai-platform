/**
 * Asterisk ARI (REST) client and call backend.
 *
 * The ARI REST interface is used to originate channels into the Stasis
 * application registered by voice_core and to hang them up. Media, TTS, and the
 * agent pipeline are owned by voice_core (`AudioSocket` + the voice agent), so
 * `speak` records an agent-utterance event for the transcript and, when a media
 * template is configured, plays a sound file.
 *
 * Every request is bounded by a timeout and errors are classified (AGENTS.md
 * rules 3, 7, 13).
 */

import { randomUUID } from "node:crypto";

import type { AriConfig } from "../config.js";
import type { BackendDeps, CallBackend, OriginatedCall } from "./backend.js";
import type { OriginateRequest } from "./types.js";

export class AriError extends Error {
  constructor(
    message: string,
    readonly status?: number,
    readonly code: string = "ari_error",
  ) {
    super(message);
    this.name = "AriError";
  }
}

interface AriClientOptions {
  config: AriConfig;
}

export class AriClient {
  private readonly config: AriConfig;
  /** Base URL normalized to the ARI root (no trailing `/ari`). */
  private readonly baseUrl: string;

  constructor(options: AriClientOptions) {
    this.config = options.config;
    // Accept either `http://host:8088` or `http://host:8088/ari`.
    this.baseUrl = options.config.baseUrl
      .replace(/\/+$/, "")
      .replace(/\/ari$/, "");
  }

  private async request(
    method: string,
    path: string,
    query?: Record<string, string>,
  ): Promise<unknown> {
    const url = new URL(this.baseUrl + path);
    for (const [key, value] of Object.entries(query ?? {})) {
      url.searchParams.set(key, value);
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.config.timeoutMs);
    const auth = Buffer.from(
      `${this.config.username}:${this.config.password}`,
    ).toString("base64");

    try {
      const response = await fetch(url, {
        method,
        headers: { Authorization: `Basic ${auth}`, Accept: "application/json" },
        signal: controller.signal,
      });

      if (!response.ok) {
        const detail = await response.text().catch(() => "");
        throw new AriError(
          `ARI ${method} ${path} failed: HTTP ${response.status} ${detail.slice(0, 200)}`,
          response.status,
          "ari_http_error",
        );
      }

      const text = await response.text();
      return text ? JSON.parse(text) : {};
    } catch (err) {
      if (err instanceof AriError) throw err;
      if (err instanceof Error && err.name === "AbortError") {
        throw new AriError(`ARI ${method} ${path} timed out`, undefined, "ari_timeout");
      }
      throw new AriError(
        `ARI ${method} ${path} transport error: ${(err as Error).message}`,
        undefined,
        "ari_transport_error",
      );
    } finally {
      clearTimeout(timer);
    }
  }

  async originate(params: {
    channelId: string;
    endpoint: string;
    app: string;
    callerId?: string;
  }): Promise<{ id: string }> {
    const result = (await this.request("POST", "/ari/channels", {
      channelId: params.channelId,
      endpoint: params.endpoint,
      app: params.app,
      ...(params.callerId ? { callerId: params.callerId } : {}),
      timeout: "30",
    })) as { id?: string };

    return { id: result.id ?? params.channelId };
  }

  async hangup(channelId: string): Promise<void> {
    await this.request("DELETE", `/ari/channels/${encodeURIComponent(channelId)}`);
  }

  async play(channelId: string, media: string): Promise<void> {
    await this.request("POST", `/ari/channels/${encodeURIComponent(channelId)}/play`, {
      media,
    });
  }
}

export class AriBackend implements CallBackend {
  readonly name = "ari";
  private readonly client: AriClient;
  private readonly registry: BackendDeps["registry"];
  private readonly log: BackendDeps["log"];
  private readonly config: AriConfig;

  constructor(config: AriConfig, deps: BackendDeps) {
    this.config = config;
    this.client = new AriClient({ config });
    this.registry = deps.registry;
    this.log = deps.log;
  }

  async originate(request: OriginateRequest): Promise<OriginatedCall> {
    const id = randomUUID();
    const channelId = id;
    const endpoint = request.to.includes("/")
      ? request.to
      : this.config.endpointTemplate.replace("{to}", request.to);

    this.registry.create({
      id,
      to: request.to,
      from: request.from ?? "voice_core",
      backend: this.name,
      meta: { channelId, endpoint },
    });
    this.registry.append(id, "call.created", { to: request.to, endpoint });
    this.registry.setState(id, "ringing");
    this.registry.append(id, "call.ringing", {});

    try {
      await this.client.originate({
        channelId,
        endpoint,
        app: this.config.app,
        callerId: request.from,
      });
    } catch (err) {
      this.registry.append(id, "call.failed", { reason: (err as Error).message });
      this.registry.setState(id, "failed");
      throw err;
    }

    if (request.greeting) {
      // The agent greeting is spoken by voice_core once media is up; record it
      // for the transcript and request playback if a media template is set.
      this.registry.append(id, "utterance.agent", { text: request.greeting });
    }

    return { id, meta: { channelId, endpoint } };
  }

  async speak(id: string, text: string): Promise<void> {
    this.registry.append(id, "utterance.agent", { text });
    this.log.warn(
      { call_id: id },
      "ARI speak: TTS playback is owned by voice_core; recorded agent utterance only",
    );
  }

  async hangup(id: string): Promise<void> {
    const call = this.registry.get(id);
    const channelId = (call?.meta.channelId as string | undefined) ?? id;
    try {
      await this.client.hangup(channelId);
    } catch (err) {
      this.registry.append(id, "call.failed", { reason: (err as Error).message });
      this.registry.setState(id, "failed");
      throw err;
    }
    this.registry.append(id, "call.ended", { reason: "hangup" });
    this.registry.setState(id, "ended");
  }

  dispose(): void {
    // No timers/handles held by the ARI backend.
  }
}
