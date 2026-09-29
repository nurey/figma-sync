# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FigmaSync do
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
      it 'gives the frame width and the numbered layer box relative to the frame' do
        drawing = described_class.annotation_drawing(boxed_frame('1:1', 'A', 'Use SVG'))

        expect(drawing).to eq(width: 400, markers: [{ number: 1, box: [50, 60, 40, 20], text: 'Use SVG' }])
      end
    end

    context 'when the frame renders beyond its bounds' do
      it 'measures from the render bounds, which is what the exported image covers' do
        document = boxed_frame('1:1', 'A', 'Use SVG', absoluteRenderBounds: box(90, 190, 420, 320))

        expect(described_class.annotation_drawing(document))
          .to eq(width: 420, markers: [{ number: 1, box: [60, 70, 40, 20], text: 'Use SVG' }])
      end
    end

    context 'when an annotation has markdown text and properties' do
      it 'uses the plain text and lists the properties' do
        document = frame('1:1', 'A', absoluteBoundingBox: box(0, 0, 10, 10),
                                     annotations: [{ 'label' => 'Bold', 'labelMarkdown' => '**Bold**',
                                                     'properties' => [{ 'type' => 'width' }] }])

        expect(described_class.annotation_drawing(document)[:markers])
          .to eq([{ number: 1, box: [0, 0, 10, 10], text: "Bold\nProperties: width" }])
      end
    end

    context 'when an annotated layer has no bounding box' do
      it 'numbers it without a box' do
        document = frame('1:1', 'A', absoluteBoundingBox: box(0, 0, 10, 10),
                                     children: [{ 'id' => '1:2', 'name' => 'Ghost', 'annotations' => [{ 'label' => 'x' }] }])

        expect(described_class.annotation_drawing(document)[:markers]).to eq([{ number: 1, box: nil, text: 'x' }])
      end
    end

    context 'when nothing is annotated' do
      it 'returns nil' do
        expect(described_class.annotation_drawing(boxed_frame('1:1', 'A', nil))).to be_nil
      end
    end
  end

  describe '.annotated_image_command' do
    context 'when the image is exported at twice the frame size' do
      it 'outlines the layer, puts a numbered badge on its corner and appends the notes' do
        drawing = { width: 400, markers: [{ number: 1, box: [50, 60, 40, 20], text: 'Use SVG' }] }

        command = described_class.annotated_image_command('in.png', 'out.png', drawing, [800, 600], '/f.ttc')

        expect(command).to eq(['magick', 'in.png', '-gravity', 'Center', '-font', '/f.ttc',
                               '-fill', 'none', '-stroke', '#F24822', '-strokewidth', '4',
                               '-draw', 'rectangle 100,120 180,160',
                               '-fill', '#F24822', '-stroke', 'none', '-draw', 'circle 100,120 120,120',
                               '-fill', 'white', '-pointsize', '24', '-annotate', '-300-180', '1',
                               '(', '-size', '640x', '-background', 'white', '-fill', '#1D1D1F', '-gravity', 'NorthWest',
                               '-pointsize', '28',
                               'caption:1. Use SVG', '-bordercolor', 'white', '-border', '32', ')',
                               '-background', 'white', '-gravity', 'NorthWest', '+append', 'out.png'])
      end
    end

    context 'when a layer sits in the corner of the image' do
      it 'keeps the badge inside the image' do
        drawing = { width: 400, markers: [{ number: 1, box: [0, 0, 10, 10], text: 'x' }] }

        command = described_class.annotated_image_command('in.png', 'out.png', drawing, [400, 300], nil)

        expect(command).to include('circle 10,10 20,10', '-190-140')
        expect(command).not_to include('-font')
      end
    end

    context 'when a marker has no box' do
      it 'lists the note without drawing a badge' do
        drawing = { width: 400, markers: [{ number: 1, box: nil, text: 'x' }] }

        command = described_class.annotated_image_command('in.png', 'out.png', drawing, [400, 300], nil)

        expect(command.grep(/circle|rectangle/)).to eq([])
        expect(command).to include('caption:1. x')
      end
    end

    context 'when the note text contains ImageMagick escapes' do
      it 'escapes them so the text is drawn literally' do
        drawing = { width: 400, markers: [{ number: 1, box: nil, text: '50% off \\n' },
                                          { number: 2, box: nil, text: 'second' }] }

        command = described_class.annotated_image_command('in.png', 'out.png', drawing, [400, 300], nil)

        expect(command).to include("caption:1. 50%% off \\\\n\n\n2. second")
      end
    end

    context 'when the frame width is unknown' do
      it 'draws at one pixel per unit' do
        drawing = { width: nil, markers: [{ number: 1, box: [50, 60, 40, 20], text: 'x' }] }

        command = described_class.annotated_image_command('in.png', 'out.png', drawing, [400, 300], nil)

        expect(command).to include('rectangle 50,60 90,80')
      end
    end
  end

  describe '.draw_annotations' do
    context 'when ImageMagick draws the image' do
      it 'writes the annotated image, wider than the source by the notes panel' do
        spec_tmpdir do |dir|
          source = File.join(dir, 'in.png')
          system('magick', '-size', '800x600', 'xc:gray', source, exception: true)
          drawing = { width: 400, markers: [{ number: 1, box: [50, 60, 40, 20], text: 'Use SVG' }] }

          drawn = described_class.draw_annotations(source, File.join(dir, 'out.png'), drawing)

          expect(drawn).to be(true)
          expect(FigmaSync.run_quiet(['magick', 'identify', '-format', '%w %h', File.join(dir, 'out.png')]))
            .to eq('1504 600')
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

    context 'when drawing fails' do
      it 'warns with the ImageMagick error, removes any partial output and returns false' do
        spec_tmpdir do |dir|
          dest = File.join(dir, 'out.png')
          File.write(dest, 'partial')
          allow(described_class).to receive(:run_quiet).and_return('800 600')
          allow(Open3).to receive(:capture3).and_return(['', "magick: boom\nmore\n",
                                                         instance_double(Process::Status, success?: false)])
          stderr = StringIO.new
          $stderr = stderr

          drawn = described_class.draw_annotations(File.join(dir, 'in.png'), dest, { width: 1, markers: [] })

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
                       { width: 400, markers: [{ number: 1, box: [50, 60, 40, 20], text: 'Use SVG' }] })
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
