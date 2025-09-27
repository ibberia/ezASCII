#!/usr/bin/env ruby
# Simple Image to ASCII Art converter
# Usage:
#   ruby ezASCII.rb INPUT_IMAGE [--width N] [--out OUTPUT.txt] [--invert]
#
# Notes:
# - Tries to use MiniMagick (ImageMagick) if available to read/resize any image.
# - Falls back to ChunkyPNG for PNG files. If neither is available, it prints a helpful message.
# - By default prints ASCII art to STDOUT. Use --out to save to a file.

require 'optparse'
require 'tempfile'

begin
  require 'mini_magick'
  HAVE_MINIMAGICK = true
rescue LoadError
  HAVE_MINIMAGICK = false
end

begin
  require 'chunky_png'
  HAVE_CHUNKYPNG = true
rescue LoadError
  HAVE_CHUNKYPNG = false
end

def abort_with(msg)
  warn msg
  exit 1
end

class AsciiArt
  DEFAULT_WIDTH = 100
  # Characters from light to dark (space is lightest)
  RAMP = " .:-=+*#%@".freeze

  def initialize(path, width: DEFAULT_WIDTH, invert: false)
    @path = path
    @target_width = width.to_i > 0 ? width.to_i : DEFAULT_WIDTH
    @invert = invert
  end

  def generate
    pixels = resized_grayscale_pixels
    ramp = @invert ? RAMP.reverse : RAMP
    max_index = ramp.length - 1

    lines = pixels.map do |row|
      row.map do |g|
        # g in 0..255
        idx = (g / 255.0 * max_index).clamp(0, max_index)
        ramp[idx.floor]
      end.join
    end

    lines.join("\n")
  end

  private

  def resized_grayscale_pixels
    if HAVE_MINIMAGICK
      return resized_pixels_with_minimagick
    end

    unless HAVE_CHUNKYPNG
      abort_with <<~MSG
        Could not load image libraries. Please install one of:
          gem install mini_magick   # requires ImageMagick on system
        or:
          gem install chunky_png    # PNG-only fallback
      MSG
    end

    # PNG-only fallback path
    unless File.extname(@path).downcase == '.png'
      abort_with "PNG-only mode: please provide a .png image or install mini_magick (and ImageMagick)."
    end

    image = ChunkyPNG::Image.from_file(@path)
    resize_and_grayscale_chunky(image)
  end

  # Use MiniMagick to load any image, convert to grayscale PNG of target size,
  # then read pixels with ChunkyPNG if available, or parse via txt if not.
  def resized_pixels_with_minimagick
    img = MiniMagick::Image.open(@path)

    tw = @target_width
    th = target_height(img.width, img.height, tw)

    # Process with ImageMagick
    img = img.clone
    img.colorspace 'Gray'
    img.resize "#{tw}x#{th}!" # explicit target size

    # Prefer reading pixels via ChunkyPNG for simplicity
    if HAVE_CHUNKYPNG
      Tempfile.create(["ascii_src", ".png"]) do |tmp|
        img.format 'png'
        img.write tmp.path
        png = ChunkyPNG::Image.from_file(tmp.path)
        return extract_grayscale_from_chunky(png)
      end
    end

    # Fallback: use ImageMagick to dump pixel values to txt and parse
    txt = img.run_command('convert', img.path, '-colorspace', 'Gray', 'txt:-')
    parse_imagemagick_txt(txt)
  end

  def target_height(orig_w, orig_h, target_w)
    return 1 if orig_w <= 0 || orig_h <= 0
    aspect = orig_h.to_f / orig_w
    # Characters are roughly twice as tall as they are wide in terminal
    char_aspect_correction = 0.5
    [(aspect * target_w * char_aspect_correction).round, 1].max
  end

  def resize_and_grayscale_chunky(image)
    tw = @target_width
    th = target_height(image.width, image.height, tw)

    # Nearest-neighbor sampling to resize
    sx = image.width.to_f / tw
    sy = image.height.to_f / th

    Array.new(th) do |y|
      src_y = (y * sy).floor.clamp(0, image.height - 1)
      Array.new(tw) do |x|
        src_x = (x * sx).floor.clamp(0, image.width - 1)
        rgba = image[src_x, src_y]
        r = ChunkyPNG::Color.r(rgba)
        g = ChunkyPNG::Color.g(rgba)
        b = ChunkyPNG::Color.b(rgba)
        a = ChunkyPNG::Color.a(rgba)
        gray = to_grayscale(r, g, b, a)
        gray
      end
    end
  end

  def extract_grayscale_from_chunky(png)
    Array.new(png.height) do |y|
      Array.new(png.width) do |x|
        rgba = png[x, y]
        r = ChunkyPNG::Color.r(rgba)
        g = ChunkyPNG::Color.g(rgba)
        b = ChunkyPNG::Color.b(rgba)
        a = ChunkyPNG::Color.a(rgba)
        to_grayscale(r, g, b, a)
      end
    end
  end

  def to_grayscale(r, g, b, a)
    # Apply alpha on white background to avoid darkening transparent areas
    alpha = a / 255.0
    r = (r * alpha + 255 * (1 - alpha)).round
    g = (g * alpha + 255 * (1 - alpha)).round
    b = (b * alpha + 255 * (1 - alpha)).round
    # Luma BT.601
    (0.299 * r + 0.587 * g + 0.114 * b).round
  end

  def parse_imagemagick_txt(txt)
    # Lines look like:
    # 0,0: (L,L,L)  #RRGGBB  gray(L)
    rows = []
    current_y = 0
    row = []
    txt.each_line do |line|
      next unless line =~ /^(\d+),(\d+):/ # skip comments/header
      x = $1.to_i
      y = $2.to_i
      if y != current_y
        rows << row unless row.empty?
        row = []
        current_y = y
      end
      if line =~ /gray\((\d+)\)/
        row << $1.to_i
      elsif line =~ /\((\d+),(\d+),(\d+)\)/
        r = $1.to_i; g = $2.to_i; b = $3.to_i
        row << (0.299 * r + 0.587 * g + 0.114 * b).round
      end
    end
    rows << row unless row.empty?
    rows
  end
end

# CLI
options = {
  width: AsciiArt::DEFAULT_WIDTH,
  out: nil,
  invert: false
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby ezASCII.rb INPUT_IMAGE [--width N] [--out OUTPUT.txt] [--invert]"
  opts.on('--width N', Integer, 'Target ASCII width (default: 100)') { |v| options[:width] = v }
  opts.on('--out FILE', String, 'Write output to file instead of STDOUT') { |v| options[:out] = v }
  opts.on('--invert', 'Invert brightness to ASCII mapping') { options[:invert] = true }
  opts.on('-h', '--help', 'Show help') do
    puts opts
    exit 0
  end
end

begin
  parser.parse!
rescue OptionParser::InvalidOption => e
  abort_with e.message + "\n\n" + parser.to_s
end

if ARGV.empty?
  puts parser
  exit 1
end

input = ARGV.shift
unless File.exist?(input)
  abort_with "Input file not found: #{input}"
end

art = AsciiArt.new(input, width: options[:width], invert: options[:invert]).generate

if options[:out]
  File.write(options[:out], art)
  puts "ASCII art saved to #{options[:out]}"
else
  puts art
end
