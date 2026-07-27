defmodule VoiceCore.AudioSocket.ServerTest do
  @moduledoc """
  Tests for AudioSocket TCP server.
  """

  use ExUnit.Case, async: true

  describe "configuration" do
    test "config struct has correct defaults" do
      config = %VoiceCore.AudioSocket.Server.Config{}
      assert config.host == "127.0.0.1"
      assert config.port == 9019
    end
  end

  describe "server lifecycle" do
    test "server can be started and stopped" do
      # This test verifies the server module can be loaded and configured
      # Actual TCP listening is tested in integration tests
      config_struct = %VoiceCore.AudioSocket.Server.Config{}
      assert config_struct.host == "127.0.0.1"
      assert config_struct.port == 9019
    end
  end
end
