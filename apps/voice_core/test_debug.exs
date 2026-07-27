defmodule TestDebug do
  def run do
    large_header = <<1::8, 0::8, 1::8, 17::8>>  # 0x010111 = 65809
    large_frame = large_header <> <<>>

    IO.puts("Frame size: #{byte_size(large_frame)}")
    IO.puts("Frame: #{:binary.bin_to_list(large_frame)}")

    # Parse the frame
    result = VoiceCore.MediaTransport.AudioSocket.parse(large_frame)
    IO.inspect(result)

    # Manual decode
    <<type::8, len1::8, len2::8, len3::8, rest::binary>> = large_frame
    length = <<len1, len2, len3>> |> :binary.decode_unsigned()
    IO.puts("Decoded length: #{length}")
    IO.puts("Max frame size: #{VoiceCore.MediaTransport.AudioSocket.@max_frame_size}")
    IO.puts("Length > Max? #{length > VoiceCore.MediaTransport.AudioSocket.@max_frame_size}")
    IO.puts("Rest size: #{byte_size(rest)}")
    IO.puts("Rest >= Length? #{byte_size(rest) >= length}")
  end
end

TestDebug.run()
