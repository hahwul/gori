require "uri"
require "./screen"
require "./theme"
require "../store"
require "../ql"

module Gori::Tui
  # The Sitemap tab: a literal host → path tree built from captured flows (no ID
  # templating — every distinct segment is its own node, P3/DESIGN.md §3). Helps
  # answer "what does this app do". Navigate with ↑/↓, expand/collapse with
  # →/←/Enter.
  class SitemapView
    # One tree node: a host (depth 0) or a path segment.
    class Node
      getter label : String
      getter children : Array(Node)
      property methods : Array(String)
      property expanded : Bool

      def initialize(@label : String)
        @children = [] of Node
        @methods = [] of String
        @expanded = true
      end

      def child(label : String) : Node
        @children.find { |c| c.label == label } || begin
          node = Node.new(label)
          @children << node
          node
        end
      end

      def leaf? : Bool
        @children.empty?
      end
    end

    def initialize
      @hosts = [] of Node
      @selected = 0
      @scroll = 0
      @loaded = false
    end

    def reload(store : Store, filter : QL::Filter = QL::EMPTY) : Nil
      @hosts = [] of Node
      store.sitemap_entries(filter).each do |(host, method, target)|
        add(host, normalize_path(target), method)
      end
      @selected = 0
      @scroll = 0
      @loaded = true
    end

    def move(delta : Int32) : Nil
      rows = visible_rows
      return if rows.empty?
      @selected = (@selected + delta).clamp(0, rows.size - 1)
    end

    # At the first (top) node — lets the Runner pop focus to the tab bar on ↑.
    def at_top? : Bool
      @selected == 0
    end

    def toggle : Nil
      node = selected_node
      node.expanded = !node.expanded if node && !node.leaf?
    end

    def expand : Nil
      node = selected_node
      node.expanded = true if node && !node.leaf?
    end

    # Collapses the selected node; returns false if there was nothing to collapse
    # (so the caller can move focus out to the sidebar).
    def collapse : Bool
      node = selected_node
      if node && !node.leaf? && node.expanded
        node.expanded = false
        true
      else
        false
      end
    end

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      unless @loaded && !@hosts.empty?
        screen.text(rect.x + 1, rect.y, "no traffic captured yet", Theme::MUTED)
        screen.text(rect.x + 1, rect.y + 2, "browse through the proxy, then return here", Theme::MUTED)
        return
      end

      rows = visible_rows
      ensure_visible(rows.size, rect.h)
      (0...rect.h).each do |i|
        ri = @scroll + i
        break if ri >= rows.size
        node, depth = rows[ri]
        y = rect.y + i
        selected = ri == @selected
        bg = selected ? (focused ? Theme::ACCENT_BG : Theme::SELECTION_DIM) : Theme::BG
        if selected
          screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
          screen.cell(rect.x, y, '▎', Theme::ACCENT, bg)
        end

        marker = node.leaf? ? " " : (node.expanded ? "▾" : "▸")
        x = rect.x + 1 + depth * 2
        screen.cell(x, y, marker[0], Theme::MUTED, bg)
        fg = depth == 0 ? Theme::TEXT_BRIGHT : Theme::TEXT
        x = screen.text(x + 2, y, node.label, fg, bg)
        unless node.methods.empty?
          tag = node.methods.join(" ")
          screen.text({rect.right - tag.size - 1, x + 1}.max, y, tag, Theme::MUTED, bg)
        end
      end
    end

    private def selected_node : Node?
      rows = visible_rows
      rows[@selected]?.try(&.[0])
    end

    private def visible_rows : Array({Node, Int32})
      rows = [] of {Node, Int32}
      @hosts.each { |host| collect(host, 0, rows) }
      rows
    end

    private def collect(node : Node, depth : Int32, rows : Array({Node, Int32})) : Nil
      rows << {node, depth}
      return unless node.expanded
      node.children.each { |child| collect(child, depth + 1, rows) }
    end

    private def add(host : String, path : String, method : String) : Nil
      host_node = @hosts.find { |h| h.label == host } || begin
        node = Node.new(host)
        @hosts << node
        node
      end
      segments = path.split('/').reject(&.empty?)
      node = segments.empty? ? host_node.child("/") : segments.reduce(host_node) { |n, seg| n.child(seg) }
      node.methods << method unless node.methods.includes?(method)
    end

    private def normalize_path(target : String) : String
      return target unless target.starts_with?("http://") || target.starts_with?("https://")
      uri = URI.parse(target)
      path = uri.path
      path = "/" if path.empty?
      uri.query ? "#{path}?#{uri.query}" : path
    rescue
      target
    end

    private def ensure_visible(total : Int32, h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = 0 if @scroll < 0
    end
  end
end
