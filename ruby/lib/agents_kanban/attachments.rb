# frozen_string_literal: true

require "digest"
require "securerandom"
require "fileutils"
require_relative "errors"
require_relative "attachment_policy"

module AgentsKanban
  # Files on cards (table card_attachments). Bytes go to <root>/<card_id>/<random hex> — never the user's name on disk;
  # the display name is sanitized, the type comes from the bytes (AttachmentPolicy). Every add / delete is logged in the
  # card's activity (kind "attachment") and touches the card, so the board and card revisions change.
  #
  # root: the host's attachment directory (injected). Reading a file resolves its realpath and refuses anything outside
  # root. URLs in JSON and markdown snippets use the board config's attachment_url_prefix: "<prefix>/<id>" and
  # "<prefix>/<id>/download".
  class Attachments
    MAX_TEXT = 100_000 # chars of a text attachment returned to an agent (kanban_attachment_get)

    attr_reader :policy, :root

    def initialize(store, root:, policy:, clock: -> { Time.now.to_i })
      @store = store
      @db = store.db
      @t = store.attachments_t
      @prefix = store.config.attachment_url_prefix
      @root = root.to_s
      @policy = policy
      @clock = clock
      raise KeyError, "attachments root is empty" if @root.strip.empty?
    end

    # The one JSON shape (API + MCP). url = the inline view (images) / the file; download_url always downloads.
    def self.json(a, prefix:)
      image = AttachmentPolicy::INLINE_IMAGES.include?(a[:content_type])
      created = a[:created_at] && Time.at(a[:created_at]).iso8601
      { id: a[:id], card_id: a[:card_id], comment_id: a[:activity_id], filename: a[:filename], content_type: a[:content_type],
        size: a[:size], sha256: a[:sha256], image: image, uploaded_by: a[:uploaded_by], created: created,
        url: "#{prefix}/#{a[:id]}", download_url: "#{prefix}/#{a[:id]}/download", markdown: snippet(a, prefix: prefix), }
    end

    # ![name](<prefix>/ID) for a picture, [name](<prefix>/ID/download) for anything else.
    def self.snippet(a, prefix:)
      name = a[:filename].gsub(/([\\\[\]*_`<>!])/) { "\\#{Regexp.last_match(1)}" }
      if AttachmentPolicy::INLINE_IMAGES.include?(a[:content_type])
        "![#{name}](#{prefix}/#{a[:id]})"
      else
        "[#{name}](#{prefix}/#{a[:id]}/download)"
      end
    end

    def json(a) = self.class.json(a, prefix: @prefix)
    def snippet(a) = self.class.snippet(a, prefix: @prefix)

    def find(id) = @t.where(id: Integer(id.to_s, exception: false) || -1).first
    def find!(id) = find(id) || raise(Invalid, "no attachment #{id}")
    def card_id_of(id) = find(id)&.dig(:card_id)
    def list(card_id) = @t.where(card_id: Integer(card_id), deleted_at: nil).order(:created_at, :id).all
    def list_json(card_id) = list(card_id).map { |a| json(a) }

    # bytes: the file's content (String). comment_id: a comment of this card it belongs to. → the row.
    def add(card_id, filename:, bytes:, by:, comment_id: nil)
      c = @store.card!(card_id)
      by = @store.who!(by)
      name = AttachmentPolicy.sanitize(filename)
      type = @policy.check!(name, bytes)
      act = nil
      if comment_id && !comment_id.to_s.empty?
        e = @store.comment!(comment_id)
        raise Invalid, "comment #{comment_id} is on card #{e[:card_id]}, not ##{c[:id]}" unless e[:card_id] == c[:id]

        act = e[:id]
      end

      dir = File.join(root_real, c[:id].to_s)
      FileUtils.mkdir_p(dir)
      rel = "#{c[:id]}/#{SecureRandom.hex(16)}"
      path = File.join(root_real, rel)
      tmp = "#{path}.part"
      File.open(tmp, "wb", 0o640) { |f| f.write(bytes) }
      File.rename(tmp, path)
      now = @clock.call
      id = @db.transaction do
        aid = @t.insert(card_id: c[:id], activity_id: act, filename: name, content_type: type, size: bytes.bytesize,
                        sha256: Digest::SHA256.hexdigest(bytes), stored_path: rel, uploaded_by: by, created_at: now)
        @store.event(c[:id], "attachment", "attached #{name} (#{human(bytes.bytesize)})", by)
        aid
      end
      find(id)
    rescue StandardError
      FileUtils.rm_f(tmp) if tmp
      FileUtils.rm_f(path) if path && !id
      raise
    end

    # An uploaded file (a multipart tempfile): the size is checked before the bytes are read.
    def add_file(card_id, filename:, io:, by:, comment_id: nil)
      size = io.respond_to?(:size) ? io.size : File.size(io.path)
      @policy.size!(size, AttachmentPolicy.sanitize(filename))
      io.rewind if io.respond_to?(:rewind)
      add(card_id, filename: filename, bytes: io.read.to_s.b, by: by, comment_id: comment_id)
    end

    # base64 from an agent: the encoded length is capped before decoding.
    def add_base64(card_id, filename:, data:, by:, comment_id: nil)
      raise Invalid, "content_base64 must be a string" unless data.is_a?(String)

      enc = data.gsub(/\s+/, "")
      limit = ((@policy.max_bytes + 2) / 3 * 4)
      raise AttachmentPolicy::TooLarge, "content_base64 decodes to more than #{@policy.max_bytes} bytes" if enc.length > limit

      # strict base64 via pack/unpack: Ruby 3.4 moved the base64 gem out of the default set, and one unpack needs no gem
      unless enc.match?(%r{\A[A-Za-z0-9+/]*={0,2}\z}) && (enc.length % 4).zero?
        raise Invalid, "content_base64 is not valid base64"
      end

      bytes = enc.unpack1("m0")
      add(card_id, filename: filename, bytes: bytes, by: by, comment_id: comment_id)
    end

    # A file inside the card's project directory (the host's read-only mount): relative to the root, or absolute under
    # it. Resolved with realpath (symlinks followed) and refused unless it stays inside. project: {slug:, path:} or nil.
    def add_project_file(card_id, project:, project_path:, filename:, by:, comment_id: nil)
      raise Invalid, "card ##{card_id} has no project on disk" unless project && project[:path]

      p = project_path.to_s
      raise Invalid, "project_path is required" if p.strip.empty?

      root = begin
        File.realpath(project[:path])
      rescue SystemCallError => e
        raise Invalid, "project #{project[:slug]} is not readable here (#{e.class.name.split('::').last})"
      end
      if p.start_with?("/")
        unless p.start_with?("#{project[:path]}/")
          raise Invalid, "project_path #{p} is outside #{project[:slug]} (#{project[:path]}); " \
                         "give a path relative to the repo root"
        end

        p = p.delete_prefix("#{project[:path]}/")
      end
      file = begin
        File.realpath(File.join(root, p))
      rescue SystemCallError
        raise Invalid, "no file #{p} in #{project[:slug]}"
      end
      raise Invalid, "project_path #{p} resolves outside #{project[:slug]}" unless file.start_with?("#{root}/")
      raise Invalid, "project_path #{p} is not a regular file" unless File.file?(file)

      @policy.size!(File.size(file), AttachmentPolicy.sanitize(filename))
      add(card_id, filename: filename, bytes: File.binread(file), by: by, comment_id: comment_id)
    end

    # Soft delete. Agents may delete only their own uploads; the operator any.
    def delete(id, by:, agent: false)
      a = find!(id)
      raise Invalid, "attachment #{a[:id]} is already deleted" if a[:deleted_at]

      by = @store.who!(by)
      if agent && a[:uploaded_by] != by
        raise Denied, "only #{a[:uploaded_by]} or the operator deletes attachment #{a[:id]} (you are #{by})"
      end

      @db.transaction do
        @t.where(id: a[:id]).update(deleted_at: @clock.call, deleted_by: by)
        @store.event(a[:card_id], "attachment", "deleted attachment #{a[:filename]}", by)
      end
      find(a[:id])
    end

    # The file on disk for a live row; refuses a stored path that resolves outside root. → absolute path.
    def path!(a)
      raise Invalid, "attachment #{a[:id]} was deleted" if a[:deleted_at]

      file = File.realpath(File.join(root_real, a[:stored_path].to_s))
      unless file.start_with?("#{root_real}/")
        raise Invalid, "attachment #{a[:id]}: stored path is outside the attachments root"
      end

      file
    rescue Errno::ENOENT
      raise Invalid, "attachment #{a[:id]}: the file is missing on disk"
    end

    # For agents: text content (capped) for text types; metadata + URLs for the rest.
    def read_for_agent(id)
      a = find!(id)
      j = json(a)
      return j.merge(deleted: a[:deleted_at] && Time.at(a[:deleted_at]).iso8601, deleted_by: a[:deleted_by]) if a[:deleted_at]
      return j unless AttachmentPolicy::TEXT_TYPES.include?(a[:content_type])

      text = File.binread(path!(a)).force_encoding(Encoding::UTF_8)
      j.merge(text: text[0, MAX_TEXT], truncated: text.length > MAX_TEXT)
    end

    def human(n)
      return "#{n} B" if n < 1024
      return format("%.1f KB", n / 1024.0) if n < 1024 * 1024

      format("%.1f MB", n / 1024.0 / 1024)
    end

    private

    def root_real
      @root_real ||= begin
        FileUtils.mkdir_p(@root)
        File.realpath(@root)
      end
    end
  end
end
