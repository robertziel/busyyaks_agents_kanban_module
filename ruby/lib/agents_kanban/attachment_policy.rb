# frozen_string_literal: true

require "json"
require_relative "errors"

module AgentsKanban
  # What may be attached, decided from the BYTES. `types` (comma-separated) is the allowlist: a MIME type from KINDS
  # enables all its extensions, a bare extension (".log" or "log") enables only that one. `max_bytes` caps one file.
  # Both are required and come from the host's config; an unknown entry fails at boot — no default, no guess.
  #
  # check! → the content type: the file's extension must be allowed, the bytes must be recognised (magic numbers; text
  # = valid UTF-8 without NUL), and both must agree. Otherwise Refused with the reason (the host answers 422).
  class AttachmentPolicy
    # Refused is an Invalid: a host answers it like any other refusal (422), TooLarge separately (413) when it wants to.
    class Refused < Invalid; end
    class TooLarge < Refused; end

    TEXT = :text
    # type => [extensions, family]. family: a binary signature key, :svg, :html, or TEXT (text types share their bytes;
    # the extension picks which one).
    KINDS = {
      "image/png" => [%w[png], :png],
      "image/jpeg" => [%w[jpg jpeg], :jpeg],
      "image/gif" => [%w[gif], :gif],
      "image/webp" => [%w[webp], :webp],
      "image/svg+xml" => [%w[svg], :svg],
      "application/pdf" => [%w[pdf], :pdf],
      "application/zip" => [%w[zip], :zip],
      "application/gzip" => [%w[gz tgz], :gzip],
      "video/mp4" => [%w[mp4 m4v], :mp4],
      "text/html" => [%w[html htm], :html],
      "text/plain" => [%w[txt log text], TEXT],
      "text/markdown" => [%w[md markdown], TEXT],
      "text/csv" => [%w[csv], TEXT],
      "application/json" => [%w[json], TEXT],
      "text/yaml" => [%w[yml yaml], TEXT],
      "text/x-diff" => [%w[diff patch], TEXT],
    }.freeze
    # Served inline (as a picture) — everything else, SVG included, is a download.
    INLINE_IMAGES = %w[image/png image/jpeg image/gif image/webp].freeze
    TEXT_TYPES = KINDS.select { |_, (_, f)| f == TEXT }.keys.freeze
    MP4_BRANDS = ['isom', 'iso2', 'iso4', 'iso5', 'iso6', 'mp41', 'mp42', 'avc1', 'M4V ', 'M4VP', 'dash'].freeze

    SVG = /\A\s*(?:<\?xml[^>]*>\s*)?(?:<!--.*?-->\s*)*(?:<!DOCTYPE[^>]*>\s*)?(?:<!--.*?-->\s*)*<svg[\s>]/mi
    HTML = /\A\s*(?:<!--.*?-->\s*)*(?:<!doctype\s+html|<html[\s>]|<head[\s>]|<body[\s>]|<script[\s>]|<iframe[\s>])/mi
    MAX_NAME = 200

    attr_reader :max_bytes, :extensions

    # max_bytes_name / types_name: how the host names the two settings in its refusals ("ATTACHMENT_MAX_BYTES").
    def initialize(max_bytes:, types:, max_bytes_name: "max_bytes", types_name: "types")
      @max_bytes_name = max_bytes_name
      @max_bytes = Integer(max_bytes.to_s, exception: false)
      raise KeyError, "#{max_bytes_name} must be a positive integer (got #{max_bytes.inspect})" unless @max_bytes&.positive?

      @extensions = {} # ext => type
      entries = types.to_s.split(",").map(&:strip).reject(&:empty?)
      raise KeyError, "#{types_name} is empty" if entries.empty?

      entries.each do |e|
        if e.include?("/")
          exts, = KINDS[e.downcase] ||
                  raise(KeyError, "#{types_name}: unknown type #{e.inspect} (known: #{KINDS.keys.join(', ')})")
          exts.each { |x| @extensions[x] = e.downcase }
        else
          x = e.delete_prefix(".").downcase
          type = KINDS.find { |_, (xs, _)| xs.include?(x) }&.first ||
                 raise(KeyError, "#{types_name}: unknown extension #{e.inspect}")
          @extensions[x] = type
        end
      end
      @extensions.freeze
    end

    def allowed = @extensions.keys.sort

    # The display name: the last path segment, control characters and slashes gone, at most MAX_NAME characters.
    def self.sanitize(name)
      n = name.to_s.dup.force_encoding(Encoding::UTF_8)
      n = n.scrub("_")
      n = n.split(%r{[/\\]}).last.to_s
      n = n.gsub(/[[:cntrl:]​-‏‪-‮⁦-⁩]/, "").strip
      n = n.sub(/\A\.+/, "")
      if n.length > MAX_NAME
        ext = File.extname(n)[0, 16]
        n = n[0, MAX_NAME - ext.length] + ext
      end
      raise Refused, "the file needs a name" if n.empty?

      n
    end

    def size!(size, name)
      raise Refused, "“#{name}” is empty" if size.zero?
      if size > @max_bytes
        raise TooLarge, "“#{name}” is #{size} bytes; the limit is #{@max_bytes} bytes (#{@max_bytes_name})"
      end
    end

    # → content type, or Refused with the reason.
    def check!(name, bytes)
      size!(bytes.bytesize, name)
      ext = File.extname(name).delete_prefix(".").downcase
      raise Refused, "“#{name}” has no extension; allowed: #{allowed.join(', ')}" if ext.empty?

      claimed = @extensions[ext] or
        raise Refused, "“#{name}”: .#{ext} is not an allowed type (allowed: #{allowed.join(', ')})"
      family = self.class.detect(bytes) or
        raise Refused, "“#{name}”: its bytes are not a recognised file type (allowed: #{allowed.join(', ')})"
      want = KINDS.fetch(claimed)[1]
      unless family == want
        raise Refused, "“#{name}”: the bytes are #{self.class.describe(family)}, the name says #{claimed} (.#{ext})"
      end
      if claimed == "application/json"
        begin
          JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8))
        rescue JSON::ParserError => e
          raise Refused, "“#{name}”: not valid JSON (#{e.message[0, 80]})"
        end
      end
      claimed
    end

    def self.describe(family)
      return "text" if family == TEXT

      KINDS.find { |_, (_, f)| f == family }&.first || family.to_s
    end

    # The family from magic numbers; text = valid UTF-8 (BOM allowed) with no NUL byte, then SVG / HTML / plain text.
    def self.detect(bytes)
      b = bytes.b
      return :png if b.start_with?("\x89PNG\r\n\x1A\n".b)
      return :jpeg if b.start_with?("\xFF\xD8\xFF".b)
      return :gif if b.start_with?("GIF87a", "GIF89a")
      return :webp if b.start_with?("RIFF") && b[8, 4] == "WEBP"
      return :pdf if b.start_with?("%PDF-")
      return :zip if b.start_with?("PK\x03\x04".b, "PK\x05\x06".b)
      return :gzip if b.start_with?("\x1F\x8B".b)
      return :mp4 if b[4, 4] == "ftyp" && MP4_BRANDS.include?(b[8, 4])
      return nil if b.include?("\x00")

      t = b.dup.force_encoding(Encoding::UTF_8)
      return nil unless t.valid_encoding?

      t = t.delete_prefix("﻿")
      head = t[0, 4096]
      return :svg if head.match?(SVG)
      return :html if head.match?(HTML)

      TEXT
    end
  end
end
