# frozen_string_literal: true

require "commonmarker"
require "strscan"
require "dependabot/pull_request_creator/message_builder"

module Dependabot
  class PullRequestCreator
    class MessageBuilder
      class LinkAndMentionSanitizer
        GITHUB_USERNAME = /[a-z0-9]+(-[a-z0-9]+)*/i.freeze
        GITHUB_REF_REGEX = %r{
          (?:https?://)?
          github\.com/(?<repo>#{GITHUB_USERNAME}/[^/\s]+)/
          (?:issue|pull)s?/(?<number>\d+)
        }x.freeze
        # rubocop:disable Metrics/LineLength
        # Context:
        # - https://github.github.com/gfm/#fenced-code-block (``` or ~~~)
        #   (?<=\n|^)         Positive look-behind to ensure we start at a line start
        #   (?>`{3,}|~{3,})   Atomic group marking the beginning of the block (3 or more chars)
        #   (?>\k<fenceopen>) Atomic group marking the end of the code block (same length as opening)
        # - https://github.github.com/gfm/#code-span
        #   (?<codespanopen>`+)  Capturing group marking the beginning of the span (1 or more chars)
        #   (?![^`]*?\n{2,})     Negative look-ahead to avoid empty lines inside code span
        #   (?:.|\n)*?           Non-capturing group to consume code span content (non-eager)
        #   (?>\k<codespanopen>) Atomic group marking the end of the code span (same length as opening)
        # rubocop:enable Metrics/LineLength
        CODEBLOCK_REGEX = /```|~~~/.freeze
        # End of string
        EOS_REGEX = /\z/.freeze
        # We rely on GitHub to do the HTML sanitization
        COMMONMARKER_OPTIONS = %i(
          UNSAFE GITHUB_PRE_LANG FULL_INFO_STRING
        ).freeze
        COMMONMARKER_EXTENSIONS = %i(
          table tasklist strikethrough autolink tagfilter
        ).freeze

        attr_reader :github_redirection_service

        def initialize(github_redirection_service:)
          @github_redirection_service = github_redirection_service
        end

        def sanitize_links_and_mentions(text:)
          doc = CommonMarker.render_doc(
            text, :LIBERAL_HTML_TAG, COMMONMARKER_EXTENSIONS
          )

          sanitize_mentions(doc)
          sanitize_links(doc)
          doc.to_html(COMMONMARKER_OPTIONS, COMMONMARKER_EXTENSIONS)
        end

        private

        def sanitize_mentions(doc)
          mention_regex = %r{(?<![A-Za-z0-9`~])@#{GITHUB_USERNAME}/?}

          doc.walk do |node|
            if node.type == :text && node.string_content.match?(mention_regex)
              nodes = []
              scan = StringScanner.new(node.string_content)

              until scan.eos?
                line = scan.scan_until(mention_regex) ||
                        scan.scan_until(EOS_REGEX)
                mention = line.match(mention_regex)&.to_s
                text_node = CommonMarker::Node.new(:text)

                if mention && !mention.end_with?("/")
                  text_node.string_content = scan.pre_match
                  nodes << text_node
                  link_node = CommonMarker::Node.new(:link)
                  text_node = CommonMarker::Node.new(:text)
                  link_node.url = "https://github.com/#{mention.tr('@', '')}"
                  text_node.string_content = "#{mention}"
                  link_node.append_child(text_node)
                  nodes << link_node
                else
                  text_node.string_content = line
                  nodes << text_node
                end
              end

              nodes.each do |n|
                node.insert_before(n)
              end

              node.delete
            end
          end
        end

        def sanitize_links(doc)
          doc.walk do |node|
            if node.type == :link && node.url.match?(GITHUB_REF_REGEX)
              node.each do |subnode|
                last_match = subnode.string_content.match(GITHUB_REF_REGEX)
                next unless subnode.type == :text && last_match

                number = last_match.named_captures.fetch("number")
                repo = last_match.named_captures.fetch("repo")
                subnode.string_content = "#{repo}##{number}"
              end

              node.url = node.url.gsub(
                "github.com", github_redirection_service || "github.com"
              )
            end
          end
        end
      end
    end
  end
end
