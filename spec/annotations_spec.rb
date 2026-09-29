# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FigmaSync do
  def note(label, **attrs)
    { 'label' => label, **attrs.transform_keys(&:to_s) }
  end

  def annotated_frame(id, name, *labels)
    frame(id, name, children: [{ 'type' => 'RECTANGLE', 'id' => "#{id}0", 'name' => 'Logo',
                                 'annotations' => labels.map { note(_1) } }])
  end

  describe '.content_hash' do
    context 'when only annotations differ' do
      it 'gives the same hash' do
        plain = frame('1:1', 'A', children: [{ 'id' => '1:2', 'name' => 'Logo' }])
        noted = frame('1:1', 'A', annotations: [note('Frame note')],
                                  children: [{ 'id' => '1:2', 'name' => 'Logo', 'annotations' => [note('Use SVG')] }])

        expect(described_class.content_hash(noted)).to eq(described_class.content_hash(plain))
      end
    end
  end

  describe '.annotations_markdown' do
    context 'when the frame and a nested node carry annotations' do
      it 'lists each annotated node under its name and id, in tree order' do
        document = frame('1:1', 'Checkout', annotations: [note('Whole screen is a modal')], children: [
                           { 'type' => 'GROUP', 'id' => '1:2', 'name' => 'Header', 'children' => [
                             { 'type' => 'TEXT', 'id' => '1:3', 'name' => 'Title',
                               'annotations' => [note('Truncate at 40 characters'), note('Use the h1 style')] }
                           ] },
                           { 'type' => 'RECTANGLE', 'id' => '1:4', 'name' => 'Divider' }
                         ])

        expect(described_class.annotations_markdown(document)).to eq(<<~MD)
          # Checkout

          ## 1. Checkout (1:1)

          Whole screen is a modal

          ## 2. Title (1:3)

          Truncate at 40 characters

          Use the h1 style
        MD
      end
    end

    context 'when an annotation has markdown text and pinned properties' do
      it 'prefers the markdown text and lists the properties' do
        bold = note('Bold', labelMarkdown: '**Bold**', properties: [{ 'type' => 'width' }, { 'type' => 'fills' }])
        document = frame('1:1', 'A', annotations: [bold])

        expect(described_class.annotations_markdown(document)).to eq(<<~MD)
          # A

          ## 1. A (1:1)

          **Bold**

          Properties: width, fills
        MD
      end
    end

    context 'when an annotation has only properties' do
      it 'lists just the properties' do
        document = frame('1:1', 'A', annotations: [{ 'properties' => [{ 'type' => 'height' }] }])

        expect(described_class.annotations_markdown(document)).to end_with("## 1. A (1:1)\n\nProperties: height\n")
      end
    end

    context 'when the only annotated node is hidden' do
      it 'returns nil' do
        document = frame('1:1', 'A', children: [{ 'id' => '1:2', 'name' => 'Old', 'visible' => false,
                                                  'annotations' => [note('Stale')] }])

        expect(described_class.annotations_markdown(document)).to be_nil
      end
    end

    context 'when no node has annotations' do
      it 'returns nil' do
        document = frame('1:1', 'A', annotations: [], children: [{ 'id' => '1:2', 'name' => 'Logo' }])

        expect(described_class.annotations_markdown(document)).to be_nil
      end
    end
  end

  describe '.main annotations' do
    before { allow(described_class).to receive(:draw_annotations).and_return(false) }

    context 'when a new frame has annotations' do
      it 'writes them next to the image and records the file in the manifest' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'), frame('1:2', 'B'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(files_under(out)).to eq(['.figma-sync.json', 'P/A__1-1.annotations.md', 'P/A__1-1.png',
                                          'P/B__1-2.png'])
          expect(File.read(File.join(out, 'P/A__1-1.annotations.md'))).to eq("# A\n\n## 1. Logo (1:10)\n\nUse SVG\n")
          expect(read_manifest(out)['nodes']).to eq(
            '1:1' => entry('P/A__1-1.png', annotated_frame('1:1', 'A', 'Use SVG'))
                     .merge('annotations' => 'P/A__1-1.annotations.md'),
            '1:2' => entry('P/B__1-2.png', frame('1:2', 'B'))
          )
        end
      end
    end

    context 'when annotations were added to an unchanged frame' do
      it 'writes them without exporting the image' do
        Dir.mktmpdir do |out|
          noted = annotated_frame('1:1', 'A', 'Use SVG')
          seed_manifest(out, nodes: { '1:1' => entry('P/A__1-1.png', noted) })
          seed_file(out, 'P/A__1-1.png', 'old image')
          client = stub_figma(pages: [page('P', noted)])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('1 frames: 0 changed, 0 new, 1 unchanged')
          expect(client).not_to have_received(:image_urls)
          expect(File.read(File.join(out, 'P/A__1-1.annotations.md'))).to include('Use SVG')
          expect(read_manifest(out).dig('nodes', '1:1', 'annotations')).to eq('P/A__1-1.annotations.md')
        end
      end
    end

    context 'when the annotations of a frame changed' do
      it 'rewrites the file' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use PNG'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(File.read(File.join(out, 'P/A__1-1.annotations.md'))).to eq("# A\n\n## 1. Logo (1:10)\n\nUse PNG\n")
        end
      end
    end

    context 'when the annotations are unchanged' do
      it 'leaves the file untouched' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          run_cli('SimKey', '--token', 'tok', '--out', out)
          path = File.join(out, 'P/A__1-1.annotations.md')
          File.utime(Time.at(0), Time.at(0), path)
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(File.mtime(path)).to eq(Time.at(0))
        end
      end
    end

    context 'when every annotation was removed from a frame' do
      it 'deletes the file and drops it from the manifest' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(files_under(out)).to eq(['.figma-sync.json', 'P/A__1-1.png'])
          expect(read_manifest(out).dig('nodes', '1:1')).not_to have_key('annotations')
        end
      end
    end

    context 'when an annotated frame was renamed' do
      it 'moves the annotations with the image' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'Old', 'Use SVG'))], version: 'v1')
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('Q', annotated_frame('1:1', 'New', 'Use SVG'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(files_under(out)).to eq(['.figma-sync.json', 'Q/New__1-1.annotations.md', 'Q/New__1-1.png'])
          expect(File.read(File.join(out, 'Q/New__1-1.annotations.md'))).to start_with("# New\n")
          expect(read_manifest(out).dig('nodes', '1:1', 'annotations')).to eq('Q/New__1-1.annotations.md')
        end
      end
    end

    context 'when the format changed' do
      it 'keeps the annotations file where it is' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          run_cli('SimKey', '--token', 'tok', '--out', out)

          run_cli('SimKey', '--token', 'tok', '--out', out, '--format', 'svg')

          expect(files_under(out)).to eq(['.figma-sync.json', 'P/A__1-1.annotations.md', 'P/A__1-1.svg'])
        end
      end
    end

    context 'when an annotated frame was removed from the file' do
      it 'deletes its annotations with its image' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'), frame('1:2', 'B'))], version: 'v1')
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', frame('1:2', 'B'))], version: 'v2')

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('(deleted 1 stale)')
          expect(files_under(out)).to eq(['.figma-sync.json', 'P/B__1-2.png'])
        end
      end
    end

    context 'when an annotated frame stopped rendering' do
      it 'deletes its annotations with its image' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG').merge('rotation' => 90))],
                     version: 'v2', images: { '1:1' => nil })

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(files_under(out)).to eq(['.figma-sync.json'])
        end
      end
    end

    context 'when a new annotated frame fails to download' do
      it 'writes no annotations for it' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'))])
          allow(client).to receive(:download).and_raise(FigmaSync::SyncError, 'download failed')

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(files_under(out)).to eq(['.figma-sync.json'])
        end
      end
    end

    context 'when an annotated frame could not be hashed' do
      it 'keeps its annotations, moving them if the frame was renamed' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'Old', 'Use SVG'))], version: 'v1')
          run_cli('SimKey', '--token', 'tok', '--out', out)
          client = stub_figma(pages: [page('P', annotated_frame('1:1', 'New', 'Use PNG'))], version: 'v2')
          allow(client).to receive(:node_documents).and_raise(FigmaSync::SyncError.new('bad', status: 404))

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(files_under(out)).to eq(['.figma-sync.json', 'P/New__1-1.annotations.md', 'P/New__1-1.png'])
          expect(File.read(File.join(out, 'P/New__1-1.annotations.md'))).to include('Use SVG')
          expect(read_manifest(out).dig('nodes', '1:1', 'annotations')).to eq('P/New__1-1.annotations.md')
        end
      end
    end

    context 'when an annotated frame that was not renamed could not be hashed' do
      it 'keeps its annotations in place' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'))], version: 'v1')
          run_cli('SimKey', '--token', 'tok', '--out', out)
          client = stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use PNG'))], version: 'v2')
          allow(client).to receive(:node_documents).and_raise(FigmaSync::SyncError.new('bad', status: 404))

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(File.read(File.join(out, 'P/A__1-1.annotations.md'))).to include('Use SVG')
          expect(read_manifest(out).dig('nodes', '1:1', 'annotations')).to eq('P/A__1-1.annotations.md')
        end
      end
    end

    context 'when a frame that could not be hashed has an annotations entry but no file' do
      it 'drops the entry' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '1:1' => { 'path' => 'P/A__1-1.png', 'hash' => nil,
                                                 'annotations' => 'P/A__1-1.annotations.md' } })
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))])
          allow(client).to receive(:node_documents).and_raise(FigmaSync::SyncError.new('bad', status: 404))

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(read_manifest(out).dig('nodes', '1:1')).not_to have_key('annotations')
        end
      end
    end

    context 'when --dry-run is given' do
      it 'writes no annotations' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', annotated_frame('1:1', 'A', 'Use SVG'))])

          run_cli('SimKey', '--token', 'tok', '--out', out, '--dry-run')

          expect(files_under(out)).to eq([])
        end
      end
    end

    context 'when a manifest entry records annotations that are not a path' do
      it 'rejects the manifest' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '1:1' => { 'path' => 'P/A__1-1.png', 'annotations' => 7 } })
          stub_figma(pages: [page('P', frame('1:1', 'A'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr).to include('is not a valid figma-sync manifest')
        end
      end
    end
  end
end
