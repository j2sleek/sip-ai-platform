defmodule VoiceCore.ARITest do
  use ExUnit.Case, async: true
  alias VoiceCore.ARI

  describe "uuid?/1" do
    test "accepts a standard UUID" do
      assert ARI.uuid?("3f0c9a1e-2b7d-4c5a-9f1b-8e2d6a4c0b3a")
    end

    test "rejects Asterisk channel ids and junk" do
      refute ARI.uuid?("PJSIP/1001-0000000a")
      refute ARI.uuid?("not-a-uuid")
      refute ARI.uuid?(nil)
      refute ARI.uuid?(123)
    end
  end

  describe "new_uuid/0" do
    test "produces a v4 UUID that uuid?/1 accepts" do
      uuid = ARI.new_uuid()
      assert ARI.uuid?(uuid)
      assert String.starts_with?(String.at(uuid, 14), "4")
    end

    test "is unique across calls" do
      assert ARI.new_uuid() != ARI.new_uuid()
    end
  end

  describe "call_id/1" do
    test "keeps a UUID channel id (outbound ARI calls) so media correlates" do
      id = ARI.new_uuid()
      assert ARI.call_id(id) == id
    end

    test "mints a UUID for a non-UUID channel id (inbound calls)" do
      call_id = ARI.call_id("PJSIP/1001-0000000a")
      assert ARI.uuid?(call_id)
      refute call_id == "PJSIP/1001-0000000a"
    end
  end
end
