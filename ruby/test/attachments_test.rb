# frozen_string_literal: true

require "test_helper"

class AttachmentPolicyTest < Minitest::Test
  P = AgentsKanban::AttachmentPolicy

  def policy(types = "image/png,image/jpeg,image/svg+xml,text/html,text/plain,application/json,.md", max = 1000)
    P.new(max_bytes: max, types: types, max_bytes_name: "ATTACHMENT_MAX_BYTES", types_name: "ATTACHMENT_TYPES")
  end

  def refused(name, bytes, p = policy) = assert_raises(P::Refused) { p.check!(name, bytes) }.message

  def test_magic_numbers_decide_the_type
    assert_equal "image/png", policy.check!("shot.png", PNG)
    assert_equal "image/jpeg", policy.check!("a.JPG", JPEG)
    assert_equal "image/svg+xml", policy.check!("i.svg", %(<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg"></svg>))
    assert_equal "text/html", policy.check!("r.html", "<!DOCTYPE html><html></html>")
    assert_equal "text/plain", policy.check!("build.log", "line 1\nline 2 ✓\n")
    assert_equal "text/markdown", policy.check!("n.md", "# hi")
    assert_equal "application/json", policy.check!("d.json", %({"a":1}))
    assert_equal :webp, P.detect("RIFF\x00\x00\x00\x00WEBPVP8 ".b)
    assert_equal :pdf, P.detect("%PDF-1.7")
    assert_nil P.detect("\x00\x01\x02binary".b)
  end

  def test_a_name_that_lies_about_the_bytes_is_refused
    assert_match "the bytes are image/jpeg, the name says image/png", refused("x.png", JPEG)
    assert_match "the bytes are text, the name says image/png", refused("x.png", "hello")
    assert_match "the bytes are text/html, the name says text/plain", refused("x.txt", "<html><script>alert(1)</script></html>")
    assert_match "the bytes are image/svg+xml, the name says text/plain", refused("x.log", "<svg onload=alert(1)>")
    assert_match "not valid JSON", refused("x.json", "{nope")
    assert_match "not a recognised file type", refused("x.txt", "\x00\x01".b)
  end

  def test_allowlist_size_env_and_sanitize
    assert_match ".exe is not an allowed type", refused("a.exe", "MZ")
    assert_match "has no extension", refused("Makefile", "all:")
    assert_match "is empty", refused("a.txt", "")
    e = assert_raises(P::TooLarge) { policy.check!("a.txt", "x" * 1001) }
    assert_match "1001 bytes; the limit is 1000 bytes (ATTACHMENT_MAX_BYTES)", e.message
    assert_match ".txt is not an allowed type", refused("a.txt", "x", policy(".md"))
    assert_raises(KeyError) { P.new(max_bytes: "", types: "image/png") }
    assert_raises(KeyError) { P.new(max_bytes: "0", types: "image/png") }
    assert_raises(KeyError) { P.new(max_bytes: "10", types: "") }
    assert_match(/ATTACHMENT_TYPES: unknown type/, assert_raises(KeyError) { policy("application/x-msdownload") }.message)
    assert_raises(KeyError) { P.new(max_bytes: "10", types: ".exe") }
    assert_equal "passwd", P.sanitize("../../etc/passwd")
    assert_equal "x.png", P.sanitize("C:\\Users\\me\\x.png")
    assert_equal "ab.png", P.sanitize("a\u0000b\r\n.png")
    assert_equal "env", P.sanitize(".env")
    assert_equal 200, P.sanitize("#{'a' * 300}.png").length
    assert_raises(P::Refused) { P.sanitize("../") }
  end
end

class AttachmentsTest < Minitest::Test
  include KanbanTest::Setup

  def setup
    super
    @root = Dir.mktmpdir("att-root")
    @repo = Dir.mktmpdir("att-repo")
    policy = AgentsKanban::AttachmentPolicy.new(max_bytes: 1000, types: "image/png,text/plain,image/svg+xml")
    @att = AgentsKanban::Attachments.new(kb, root: @root, policy: policy, clock: -> { @now })
    @card = kb.create(slug: "g/r", title: "T", by: "op")
  end

  def teardown
    FileUtils.rm_rf([@root, @repo])
    super
  end

  def test_add_stores_under_a_random_name_and_logs
    a = @att.add(@card, filename: "../evil/shot.png", bytes: PNG, by: "op")
    assert_equal ["shot.png", "image/png", PNG.bytesize, "op"], a.values_at(:filename, :content_type, :size, :uploaded_by)
    assert_match %r{\A#{@card}/\h{32}\z}, a[:stored_path]
    assert_equal PNG, File.binread(File.join(@root, a[:stored_path]))
    assert_equal Digest::SHA256.hexdigest(PNG), a[:sha256]
    assert_equal "attached shot.png (#{PNG.bytesize} B)", kb.activity(@card).last[:body]
    j = @att.json(a)
    assert_equal ["![shot.png](/api/attachments/#{a[:id]})", true, "/api/attachments/#{a[:id]}/download"],
                 j.values_at(:markdown, :image, :download_url)
    t = @att.add(@card, filename: "a [b].txt", bytes: "x", by: "op")
    assert_equal "[a \\[b\\].txt](/api/attachments/#{t[:id]}/download)", @att.json(t)[:markdown]
    refute @att.json(@att.add(@card, filename: "i.svg", bytes: "<svg></svg>", by: "op"))[:image]
    assert_equal 3, kb.card(@card)[:attachments]
    assert_equal 3, kb.card_json(kb.board("g/r")["backlog"].first)[:attachments]
  end

  def test_revision_changes_on_add_and_delete
    rev = -> { AgentsKanban::Rev.of(kb.card_body(kb.card(@card))) }
    c0 = rev.call
    a = @att.add(@card, filename: "a.png", bytes: PNG, by: "op")
    c1 = rev.call
    refute_equal c0, c1
    @att.delete(a[:id], by: "op")
    refute_equal c1, rev.call
  end

  def test_soft_delete_and_who_may
    a = @att.add(@card, filename: "a.txt", bytes: "x", by: "agent-a")
    e = assert_raises(AgentsKanban::Denied) { @att.delete(a[:id], by: "agent-b", agent: true) }
    assert_match "only agent-a or the operator", e.message
    d = @att.delete(a[:id], by: "op")
    assert_equal "op", d[:deleted_by]
    assert File.exist?(File.join(@root, a[:stored_path])), "a soft delete keeps the bytes"
    assert_equal "deleted attachment a.txt", kb.activity(@card).last[:body]
    assert_empty @att.list(@card)
    assert_raises(AgentsKanban::Invalid) { @att.path!(d) }
    assert_match "already deleted", assert_raises(AgentsKanban::Invalid) { @att.delete(a[:id], by: "op") }.message
    own = @att.add(@card, filename: "b.txt", bytes: "x", by: "agent-a")
    assert @att.delete(own[:id], by: "agent-a", agent: true)[:deleted_at]
  end

  def test_stored_path_outside_the_root_is_refused
    a = @att.add(@card, filename: "a.txt", bytes: "x", by: "op")
    outside = File.join(@repo, "secret.txt")
    File.write(outside, "secret")
    kb.attachments_t.where(id: a[:id]).update(stored_path: "../#{File.basename(@repo)}/secret.txt")
    assert_match "outside the attachments root", assert_raises(AgentsKanban::Invalid) { @att.path!(@att.find(a[:id])) }.message
    File.symlink(outside, File.join(@root, "link"))
    kb.attachments_t.where(id: a[:id]).update(stored_path: "link")
    assert_raises(AgentsKanban::Invalid) { @att.path!(@att.find(a[:id])) }
  end

  def test_comment_links_its_authors_attachments_and_comment_id_must_be_on_the_card
    a = @att.add(@card, filename: "a.png", bytes: PNG, by: "op")
    other = @att.add(@card, filename: "b.png", bytes: PNG, by: "someone-else")
    cid = kb.comment(@card, body: "see ![a](/api/attachments/#{a[:id]}) ![b](/api/attachments/#{other[:id]})", author: "op")
    assert_equal cid, @att.find(a[:id])[:activity_id]
    assert_nil @att.find(other[:id])[:activity_id]
    kb.comment_delete(cid, by: "op")
    assert_nil @att.find(a[:id])[:activity_id], "the file stays on the card when its comment goes"
    o = kb.create(slug: "g/r", title: "O", by: "op")
    oc = kb.comment(o, body: "x", author: "op")
    e = assert_raises(AgentsKanban::Invalid) { @att.add(@card, filename: "a.txt", bytes: "x", by: "op", comment_id: oc) }
    assert_match "is on card #{o}", e.message
    own = kb.comment(@card, body: "y", author: "op")
    assert_equal own, @att.add(@card, filename: "a.txt", bytes: "x", by: "op", comment_id: own)[:activity_id]
  end

  def test_project_path_stays_inside_the_repo_and_base64_cap
    p = { slug: "g/r", path: @repo }
    FileUtils.mkdir_p(File.join(@repo, "logs"))
    File.write(File.join(@repo, "logs/run.log"), "ok\n")
    a = @att.add_project_file(@card, project: p, project_path: "logs/run.log", filename: "run.log", by: "agent")
    assert_equal "ok\n", File.read(File.join(@root, a[:stored_path]))
    assert @att.add_project_file(@card, project: p, project_path: File.join(@repo, "logs/run.log"),
                                        filename: "run.log", by: "agent")
    secret = Dir.mktmpdir("att-outside")
    File.write(File.join(secret, "s.txt"), "secret")
    File.symlink(File.join(secret, "s.txt"), File.join(@repo, "escape.txt"))
    [
      ["../#{File.basename(secret)}/s.txt", "outside|no file"],
      ["escape.txt", "resolves outside"],
      ["/etc/hostname", "is outside g/r"],
      ["logs", "not a regular file"],
      ["nope.txt", "no file nope.txt"],
    ].each do |path, want|
      e = assert_raises(AgentsKanban::Invalid, path) { @att.add_project_file(@card, project: p, project_path: path, filename: "x.txt", by: "agent") }
      assert_match Regexp.new(want), e.message, path
    end
    assert_raises(AgentsKanban::AttachmentPolicy::TooLarge) { @att.add_base64(@card, filename: "a.txt", data: ["x" * 2000].pack("m0"), by: "a") }
    e = assert_raises(AgentsKanban::Invalid) { @att.add_base64(@card, filename: "a.txt", data: "@@@", by: "a") }
    assert_match "not valid base64", e.message
    hi = @att.add_base64(@card, filename: "a.txt", data: ["hi"].pack("m0"), by: "a")
    assert_equal "hi", File.read(File.join(@root, hi[:stored_path]))
  ensure
    FileUtils.rm_rf(secret) if secret
  end

  def test_markdown_renders_only_this_hosts_attachments
    a = @att.add(@card, filename: "s.png", bytes: PNG, by: "op")
    f = @att.add(@card, filename: "run.log", bytes: "ok", by: "op")
    html = md.card("#{@att.snippet(a)} #{@att.snippet(f)} ![x](https://evil.example/t.png)")
    assert_includes html, %(<img src="/api/attachments/#{a[:id]}")
    assert_includes html, %(class="kb-file-chip" href="/api/attachments/#{f[:id]}/download")
    refute_includes html, %(src="https://evil.example)
    assert_equal 1, html.scan("<img").size
    other = AgentsKanban::Markdown.new(attachment_url_prefix: "/kanban/attachments")
    assert_equal 0, other.card(@att.snippet(a)).scan("<img").size, "another host's prefix is not ours"
  end
end
