defmodule VoiceCoreTest do
  use ExUnit.Case, async: true

  doctest VoiceCore

  describe "health/0" do
    test "returns :ok when the supervision tree is running" do
      assert VoiceCore.health() == :ok
    end

    test "the top-level supervisor is alive" do
      pid = Process.whereis(VoiceCore.Supervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "health_report/0" do
    test "conforms to the HealthResponse contract" do
      report = VoiceCore.health_report()
      assert report.status == "ok"
      assert report.service == "voice_core"
      assert is_binary(report.version)
    end
  end

  describe "config" do
    test "app_env/0 returns a string (environment-driven, defaults to development)" do
      assert is_binary(VoiceCore.app_env())
    end
  end
end
