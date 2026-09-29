# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FigmaSync do
  def style
    { width: 280, padding: 12, gap: 8, margin: 24, radius: 8, text_size: 14, line_spacing: 4, dot: 3, line: 1,
      dash: 4, border: 1 }
  end

  def box(x, y, width, height)
    { 'x' => x, 'y' => y, 'width' => width, 'height' => height }
  end

  def boxed_frame(id, name, label, **attrs)
    frame(id, name, absoluteBoundingBox: box(100, 200, 400, 300), **attrs,
                    children: [{ 'type' => 'RECTANGLE', 'id' => "#{id}0", 'name' => 'Logo',
                                 'absoluteBoundingBox' => box(150, 260, 40, 20),
                                 'annotations' => label ? [{ 'label' => label }] : [] }])
  end

  def stub_drawing
    allow(described_class).to receive(:draw_annotations) do |_source, dest, _drawing|
      File.write(dest, 'annotated')
      true
    end
  end

  describe '.annotation_drawing' do
    context 'when a layer inside the frame is annotated' do
      it 'gives the frame width and the layer box relative to the frame' do
        drawing = described_class.annotation_drawing(boxed_frame('1:1', 'A', 'Use SVG'))

        expect(drawing).to eq(width: 400, markers: [{ box: [50, 60, 40, 20], text: 'Use SVG' }])
      end
    end

    context 'when the frame renders beyond its bounds' do
      it 'measures from the render bounds, which is what the exported image covers' do
        document = boxed_frame('1:1', 'A', 'Use SVG', absoluteRenderBounds: box(90, 190, 420, 320))

        expect(described_class.annotation_drawing(document))
          .to eq(width: 420, markers: [{ box: [60, 70, 40, 20], text: 'Use SVG' }])
      end
    end

    context 'when an annotation has markdown text and properties' do
      it 'uses the plain text and lists the properties' do
        document = frame('1:1', 'A', absoluteBoundingBox: box(0, 0, 10, 10),
                                     annotations: [{ 'label' => 'Bold', 'labelMarkdown' => '**Bold**',
                                                     'properties' => [{ 'type' => 'width' }] }])

        expect(described_class.annotation_drawing(document)[:markers])
          .to eq([{ box: [0, 0, 10, 10], text: "Bold\nProperties: width" }])
      end
    end

    context 'when an annotated layer has no bounding box' do
      it 'gives it no box' do
        document = frame('1:1', 'A', absoluteBoundingBox: box(0, 0, 10, 10),
                                     children: [{ 'id' => '1:2', 'name' => 'Ghost', 'annotations' => [{ 'label' => 'x' }] }])

        expect(described_class.annotation_drawing(document)[:markers]).to eq([{ box: nil, text: 'x' }])
      end
    end

    context 'when nothing is annotated' do
      it 'returns nil' do
        expect(described_class.annotation_drawing(boxed_frame('1:1', 'A', nil))).to be_nil
      end
    end
  end

  describe '.callout_layout' do
    def flat_style
      style.merge(line_spacing: 0)
    end

    def marker(box, text = 'x')
      { box:, text: }
    end

    context 'when one layer is annotated' do
      it 'centres the callout on the layer and draws the leader from its right edge' do
        layout = described_class.callout_layout([marker([50, 60, 40, 20], 'Use SVG')], [400, 300], [32], flat_style)

        expect(layout).to eq(canvas: [728, 300],
                             callouts: [{ rect: [424, 42, 704, 98], text_at: [436, 54], text: 'Use SVG',
                                          leader: [90, 70, 424, 70] }])
      end
    end

    context 'when two callouts would overlap' do
      it 'pushes the lower one down and keeps its leader inside the layer' do
        layout = described_class.callout_layout([marker([50, 60, 40, 20]), marker([50, 60, 40, 20])],
                                                [400, 300], [32, 32], flat_style)

        expect(layout[:callouts].map { _1[:rect] }).to eq([[424, 42, 704, 98], [424, 106, 704, 162]])
        expect(layout[:callouts].last[:leader]).to eq([90, 80, 424, 134])
      end
    end

    context 'when the layers are out of order in the tree' do
      it 'orders the callouts top to bottom' do
        layout = described_class.callout_layout([marker([0, 200, 10, 10], 'low'), marker([0, 10, 10, 10], 'high')],
                                                [400, 300], [16, 16], flat_style)

        expect(layout[:callouts].map { _1[:text] }).to eq(%w[high low])
      end
    end

    context 'when a layer is near the top of the image' do
      it 'keeps the callout inside the margin' do
        layout = described_class.callout_layout([marker([0, 0, 10, 10])], [400, 300], [16], flat_style)

        expect(layout[:callouts].first[:rect]).to eq([424, 24, 704, 64])
      end
    end

    context 'when a layer has no box' do
      it 'puts its callout after the others without a leader' do
        layout = described_class.callout_layout([marker(nil, 'loose'), marker([0, 100, 10, 10], 'placed')],
                                                [400, 300], [16, 16], flat_style)

        expect(layout[:callouts].map { [_1[:text], _1[:rect][1], _1[:leader]] })
          .to eq([['placed', 85, [10, 105, 424, 105]], ['loose', 133, nil]])
      end
    end

    context 'when the callouts run past the bottom of the image' do
      it 'makes the canvas taller' do
        layout = described_class.callout_layout([marker([0, 250, 10, 10])], [400, 300], [200], flat_style)

        expect(layout[:canvas]).to eq([728, 391])
      end
    end
  
    context 'when the text has line spacing' do
      it 'drops the spacing ImageMagick adds after the last line' do
        layout = described_class.callout_layout([marker(nil)], [400, 300], [20], style)

        expect(layout[:callouts].first[:rect]).to eq([424, 24, 704, 64])
      end
    end
  end

  describe '.callout_measure_command' do
    context 'when a font is available' do
      it 'measures every callout text in one call, escaped' do
        command = described_class.callout_measure_command(['a', '50% \\n'], style, '/f.ttc')

        expect(command).to eq(['magick', '-font', '/f.ttc', '-pointsize', '14', '-interline-spacing', '4',
                               '-size', '256x', 'caption:a',
                               'caption:50%% \\\\n', '-format', "%h\n", 'info:'])
      end
    end

    context 'when no font is available' do
      it 'leaves the font to ImageMagick' do
        expect(described_class.callout_measure_command(['a'], style, nil)).not_to include('-font')
      end
    end
  end

  describe '.callout_image_command' do
    context 'when there is one callout' do
      it 'extends the canvas, draws the leader and dot, the callout box, then its text' do
        layout = { canvas: [728, 300], callouts: [{ rect: [424, 42, 704, 98], text_at: [436, 54], text: 'Use SVG',
                                                    leader: [90, 70, 424, 70] }] }

        command = described_class.callout_image_command('in.png', 'out.png', layout, style, '/f.ttc')

        expect(command).to eq(['magick', 'in.png', '-font', '/f.ttc', '-background', '#3C3C3C',
                               '-gravity', 'NorthWest', '-extent', '728x300',
                               '-fill', 'none', '-stroke', '#FFFFFF99', '-strokewidth', '3',
                               '-draw', 'line 90,70 424,70', '-stroke', '#8C8C8C', '-strokewidth', '1',
                               '-draw', 'stroke-dasharray 4 4 line 90,70 424,70',
                               '-fill', '#8C8C8C', '-stroke', 'none', '-draw', 'circle 90,70 93,70',
                               '-fill', '#2C2C2C', '-stroke', '#4D4D4D', '-strokewidth', '1',
                               '-draw', 'roundrectangle 424,42 704,98 8,8',
                               '(', '-size', '256x', '-background', 'none', '-fill', '#F5F5F5', '-stroke', 'none',
                               '-pointsize', '14',
                               '-interline-spacing', '4', 'caption:Use SVG', ')', '-geometry', '+436+54', '-composite',
                               'out.png'])
      end
    end

    context 'when a callout has no leader and there is no font' do
      it 'draws only the callout' do
        layout = { canvas: [728, 300], callouts: [{ rect: [424, 24, 704, 64], text_at: [436, 36], text: 'x',
                                                    leader: nil }] }

        command = described_class.callout_image_command('in.png', 'out.png', layout, style, nil)

        expect(command.grep(/stroke-dasharray|circle|\A-font\z/)).to eq([])
      end
    end
  end

  describe '.annotation_font' do
    context 'when Inter is installed for the user' do
      it 'uses Inter, the font Figma draws annotations in' do
        inter = File.join(Dir.home, 'Library/Fonts/Inter-Regular.otf')
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(inter).and_return(true)

        expect(described_class.annotation_font).to eq(inter)
      end
    end

    context 'when only Helvetica is available' do
      it 'falls back to Helvetica' do
        allow(File).to receive(:exist?).and_return(false)
        allow(File).to receive(:exist?).with('/System/Library/Fonts/Helvetica.ttc').and_return(true)

        expect(described_class.annotation_font).to eq('/System/Library/Fonts/Helvetica.ttc')
      end
    end

    context 'when no known font is installed' do
      it 'returns nil so ImageMagick picks one' do
        allow(File).to receive(:exist?).and_return(false)

        expect(described_class.annotation_font).to be_nil
      end
    end
  end

  describe '.draw_annotations' do
    context 'when ImageMagick draws the image' do
      it 'writes the annotated image, wider than the source by the callout gutter' do
        spec_tmpdir do |dir|
          source = File.join(dir, 'in.png')
          system('magick', '-size', '800x600', 'xc:gray', source, exception: true)
          drawing = { width: 400, markers: [{ box: [50, 60, 40, 20], text: 'Use SVG' }] }

          drawn = described_class.draw_annotations(source, File.join(dir, 'out.png'), drawing)

          expect(drawn).to be(true)
          expect(FigmaSync.run_quiet(['magick', 'identify', '-format', '%w %h', File.join(dir, 'out.png')]))
            .to eq('1480 600')
        end
      end
    end

    context 'when the source cannot be read' do
      it 'warns and returns false' do
        spec_tmpdir do |dir|
          source = File.join(dir, 'in.png')
          File.write(source, 'not an image')
          stderr = StringIO.new
          $stderr = stderr

          drawn = described_class.draw_annotations(source, File.join(dir, 'out.png'), { width: 1, markers: [] })

          expect(drawn).to be(false)
          expect(stderr.string).to eq("warning: could not draw annotations on in.png (cannot read the image)\n")
        ensure
          $stderr = STDERR
        end
      end
    end

    context 'when the callout text cannot be measured' do
      it 'warns and returns false' do
        allow(described_class).to receive(:run_quiet).and_return('800 600', nil)
        stderr = StringIO.new
        $stderr = stderr

        drawn = described_class.draw_annotations('/x/in.png', '/x/out.png',
                                                 { width: 1, markers: [{ box: nil, text: 'x' }] })

        expect(drawn).to be(false)
        expect(stderr.string).to eq("warning: could not draw annotations on in.png (cannot measure the notes)\n")
      ensure
        $stderr = STDERR
      end
    end

    context 'when drawing fails' do
      it 'warns with the ImageMagick error, removes any partial output and returns false' do
        spec_tmpdir do |dir|
          dest = File.join(dir, 'out.png')
          File.write(dest, 'partial')
          allow(described_class).to receive(:run_quiet).and_return('800 600', "16\n")
          allow(Open3).to receive(:capture3).and_return(['', "magick: boom\nmore\n",
                                                         instance_double(Process::Status, success?: false)])
          stderr = StringIO.new
          $stderr = stderr

          drawn = described_class.draw_annotations(File.join(dir, 'in.png'), dest,
                                                   { width: 1, markers: [{ box: nil, text: 'x' }] })

          expect(drawn).to be(false)
          expect(File.exist?(dest)).to be(false)
          expect(stderr.string).to eq("warning: could not draw annotations on in.png (magick: boom)\n")
        ensure
          $stderr = STDERR
        end
      end
    end
  end

  describe '.main annotated images' do
    context 'when a new frame has annotations' do
      it 'draws an annotated copy next to the image and records it' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'), frame('1:2', 'B'))])
          stub_drawing

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(described_class).to have_received(:draw_annotations)
            .once.with(File.join(out, 'P/A__1-1.png'), File.join(out, 'P/A__1-1.annotated.png'),
                       { width: 400, markers: [{ box: [50, 60, 40, 20], text: 'Use SVG' }] })
          expect(files_under(out)).to eq(['.figma-sync.json', 'P/A__1-1.annotated.png', 'P/A__1-1.annotations.md',
                                          'P/A__1-1.png', 'P/B__1-2.png'])
          expect(read_manifest(out).dig('nodes', '1:1', 'annotated')).to eq('P/A__1-1.annotated.png')
          expect(read_manifest(out).dig('nodes', '1:2')).not_to have_key('annotated')
        end
      end
    end

    context 'when neither the image nor the annotations changed' do
      it 'keeps the annotated copy without drawing it again' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(described_class).to have_received(:draw_annotations).once
          expect(read_manifest(out).dig('nodes', '1:1', 'annotated')).to eq('P/A__1-1.annotated.png')
        end
      end
    end

    context 'when only the annotations changed' do
      it 'draws the annotated copy again without exporting the image' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)
          client = stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use PNG'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(client).not_to have_received(:image_urls)
          expect(described_class).to have_received(:draw_annotations).twice
        end
      end
    end

    context 'when only the image changed' do
      it 'draws the annotated copy again' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG', rotation: 90))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(described_class).to have_received(:draw_annotations).twice
        end
      end
    end

    context 'when the annotated copy was deleted from the folder' do
      it 'draws it again' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)
          File.unlink(File.join(out, 'P/A__1-1.annotated.png'))
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(File.read(File.join(out, 'P/A__1-1.annotated.png'))).to eq('annotated')
          expect(described_class).to have_received(:draw_annotations).twice
        end
      end
    end

    context 'when an unchanged annotated frame was renamed' do
      it 'moves the annotated copy without drawing it again' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'Old', 'Use SVG'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', boxed_frame('1:1', 'New', 'Use SVG'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(files_under(out)).to eq(['.figma-sync.json', 'P/New__1-1.annotated.png', 'P/New__1-1.annotations.md',
                                          'P/New__1-1.png'])
          expect(described_class).to have_received(:draw_annotations).once
        end
      end
    end

    context 'when an annotated frame was renamed and its annotations changed' do
      it 'draws the copy at the new path and deletes the old one' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'Old', 'Use SVG'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', boxed_frame('1:1', 'New', 'Use PNG'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(files_under(out)).to eq(['.figma-sync.json', 'P/New__1-1.annotated.png', 'P/New__1-1.annotations.md',
                                          'P/New__1-1.png'])
          expect(described_class).to have_received(:draw_annotations).twice
        end
      end
    end

    context 'when every annotation was removed' do
      it 'deletes the annotated copy' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', nil))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(files_under(out)).to eq(['.figma-sync.json', 'P/A__1-1.png'])
          expect(read_manifest(out).dig('nodes', '1:1')).not_to have_key('annotated')
        end
      end
    end

    context 'when the format is svg' do
      it 'draws no annotated copy and deletes the one from an earlier png export' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)

          run_cli('SimKey', '--token', 'tok', '--out', out, '--format', 'svg')

          expect(files_under(out)).to eq(['.figma-sync.json', 'P/A__1-1.annotations.md', 'P/A__1-1.svg'])
          expect(described_class).to have_received(:draw_annotations).once
        end
      end
    end

    context 'when the format changed from png to jpg' do
      it 'replaces the annotated copy with one in the new format' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)

          run_cli('SimKey', '--token', 'tok', '--out', out, '--format', 'jpg')

          expect(files_under(out)).to eq(['.figma-sync.json', 'P/A__1-1.annotated.jpg', 'P/A__1-1.annotations.md',
                                          'P/A__1-1.jpg'])
        end
      end
    end

    context 'when an annotated frame was removed from the file' do
      it 'deletes the annotated copy' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'), frame('1:2', 'B'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', frame('1:2', 'B'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(files_under(out)).to eq(['.figma-sync.json', 'P/B__1-2.png'])
        end
      end
    end

    context 'when drawing fails' do
      it 'records no annotated copy and finishes the run' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))])
          allow(described_class).to receive(:draw_annotations).and_return(false)

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(read_manifest(out).dig('nodes', '1:1')).not_to have_key('annotated')
        end
      end
    end

    context 'when ImageMagick is not installed' do
      it 'exits 1 with install instructions before calling Figma' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))])
          allow(described_class).to receive(:run_quiet).and_call_original
          allow(described_class).to receive(:run_quiet).with(%w[magick -version]).and_return(nil)

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr).to eq("figma-sync: #{FigmaSync::MAGICK_REQUIRED}\n")
          expect(client).not_to have_received(:get_file)
          expect(files_under(out)).to eq([])
        end
      end
    end

    context 'when an annotated frame could not be hashed' do
      it 'keeps the annotated copy' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          stub_drawing
          run_cli('SimKey', '--token', 'tok', '--out', out)
          client = stub_figma(pages: [page('P', boxed_frame('1:1', 'A', 'Use PNG'))], version: 'v2')
          allow(client).to receive(:node_documents).and_raise(FigmaSync::SyncError.new('bad', status: 404))

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(read_manifest(out).dig('nodes', '1:1', 'annotated')).to eq('P/A__1-1.annotated.png')
          expect(described_class).to have_received(:draw_annotations).once
        end
      end
    end

    context 'when a manifest entry records an annotated copy that is not a path' do
      it 'rejects the manifest' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '1:1' => { 'path' => 'P/A__1-1.png', 'annotated' => [] } })
          stub_figma(pages: [page('P', frame('1:1', 'A'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('is not a valid figma-sync manifest')
        end
      end
    end
  end
end
