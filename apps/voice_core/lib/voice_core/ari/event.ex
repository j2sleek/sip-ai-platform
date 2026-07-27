defmodule VoiceCore.ARI.Event do
  defstruct [:type, :application, :timestamp, :channel, :extra]

  defmodule StasisStart do
    defstruct [:type, :application, :timestamp, :channel, :args]
  end

  defmodule ChannelStateChange do
    defstruct [:type, :application, :timestamp, :channel]
  end

  defmodule ChannelDestroyed do
    defstruct [:type, :application, :timestamp, :channel, :cause]
  end

  defmodule Unknown do
    defstruct [:type, :raw]
  end
end
