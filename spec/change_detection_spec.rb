# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FigmaSync do
  describe '.content_hash' do
    context 'when two documents differ only in key order' do
      it 'gives the same hash' do
        a = { 'id' => '1:1', 'fills' => [{ 'type' => 'SOLID', 'color' => { 'r' => 1, 'g' => 0 } }], 'name' => 'A' }
        b = { 'name' => 'A', 'fills' => [{ 'color' => { 'g' => 0, 'r' => 1 }, 'type' => 'SOLID' }], 'id' => '1:1' }

        expect(described_class.content_hash(a)).to eq(described_class.content_hash(b))
      end
    end

    context 'when a value or the order of an array differs' do
      it 'gives a different hash' do
        base = { 'children' => [{ 'id' => 'a' }, { 'id' => 'b' }], 'opacity' => 1 }

        expect(described_class.content_hash(base.merge('opacity' => 0.5))).not_to eq(described_class.content_hash(base))
        expect(described_class.content_hash(base.merge('children' => base['children'].reverse)))
          .not_to eq(described_class.content_hash(base))
      end
    end

    context 'when only the root node is renamed' do
      it 'gives the same hash' do
        before = frame('1:1', 'Old', children: [{ 'id' => '1:2', 'name' => 'Label' }])
        after = frame('1:1', 'New', children: [{ 'id' => '1:2', 'name' => 'Label' }])

        expect(described_class.content_hash(after)).to eq(described_class.content_hash(before))
      end
    end

    context 'when a child node is renamed' do
      it 'gives a different hash' do
        before = frame('1:1', 'A', children: [{ 'id' => '1:2', 'name' => 'Label' }])
        after = frame('1:1', 'A', children: [{ 'id' => '1:2', 'name' => 'Caption' }])

        expect(described_class.content_hash(after)).not_to eq(described_class.content_hash(before))
      end
    end

    context 'when the document is nested more than 100 levels deep' do
      it 'hashes it' do
        deep = (1..150).reduce({ 'id' => 'leaf' }) { |child, i| { 'id' => "g#{i}", 'children' => [child] } }

        expect(described_class.content_hash(deep)).to match(/\A\h{64}\z/)
      end
    end

    context 'when the document is nil' do
      it 'returns nil' do
        expect(described_class.content_hash(nil)).to be_nil
      end
    end
  end

  describe '.main change detection' do
    context 'when a frame is unchanged' do
      it 'requests no image and carries its entry forward' do
        Dir.mktmpdir do |out|
          a = frame('1:1', 'A', children: [{ 'type' => 'TEXT', 'id' => '1:9', 'characters' => 'Hello' }])
          seed_manifest(out, version: 'v1', nodes: { '1:1' => entry('P/A__1-1.png', a) })
          seed_file(out, 'P/A__1-1.png', 'old image')
          client = stub_figma(pages: [page('P', a)], version: 'v2')

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(result.stderr).to include("1 frames: 0 changed, 0 new, 1 unchanged\n", 'Exported 0 frames')
          expect(client).not_to have_received(:image_urls)
          expect(File.read(File.join(out, 'P/A__1-1.png'))).to eq('old image')
          expect(read_manifest(out)).to include('version' => 'v2', 'nodes' => { '1:1' => entry('P/A__1-1.png', a) })
        end
      end
    end

    context 'when a frame changed' do
      it 'exports it and stores the new hash' do
        Dir.mktmpdir do |out|
          before = frame('1:1', 'A', children: [{ 'type' => 'TEXT', 'id' => '1:9', 'characters' => 'Hello' }])
          after = frame('1:1', 'A', children: [{ 'type' => 'TEXT', 'id' => '1:9', 'characters' => 'Hello!' }])
          seed_manifest(out, nodes: { '1:1' => entry('P/A__1-1.png', before) })
          seed_file(out, 'P/A__1-1.png', 'old image')
          client = stub_figma(pages: [page('P', after)])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('1 frames: 1 changed, 0 new, 0 unchanged')
          expect(client).to have_received(:image_urls).with('SimKey', ['1:1'], fmt: 'png', scale: 2.0)
          expect(File.read(File.join(out, 'P/A__1-1.png'))).to eq('image from https://images.example/1:1')
          expect(read_manifest(out)['nodes']).to eq('1:1' => entry('P/A__1-1.png', after))
        end
      end
    end

    context 'when only some frames changed' do
      it 'sends only those frames to the images endpoint' do
        Dir.mktmpdir do |out|
          same = frame('1:1', 'Same')
          edited = frame('1:2', 'Edited', opacity: 0.5)
          seed_manifest(out, nodes: { '1:1' => entry('P/Same__1-1.png', same),
                                      '1:2' => entry('P/Edited__1-2.png', frame('1:2', 'Edited')) })
          seed_file(out, 'P/Same__1-1.png')
          seed_file(out, 'P/Edited__1-2.png')
          client = stub_figma(pages: [page('P', same, edited, frame('1:3', 'Added'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('3 frames: 1 changed, 1 new, 1 unchanged', '[1/1] P: 2 frames')
          expect(client).to have_received(:image_urls).once.with('SimKey', %w[1:2 1:3], fmt: 'png', scale: 2.0)
        end
      end
    end

    context 'when the manifest comes from before hashes were stored' do
      it 'exports every frame once, then treats them as unchanged' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '1:1' => 'P/A__1-1.png' })
          seed_file(out, 'P/A__1-1.png')
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))], version: 'v2')
          first = run_cli('SimKey', '--token', 'tok', '--out', out)
          stub_figma(pages: [page('P', frame('1:1', 'A'))], version: 'v3')

          second = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(first.stderr).to include('1 frames: 1 changed, 0 new, 0 unchanged')
          expect(second.stderr).to include('1 frames: 0 changed, 0 new, 1 unchanged')
          expect(client).to have_received(:image_urls).once
          expect(read_manifest(out)).to include('manifestVersion' => 2, 'version' => 'v3',
                                                'nodes' => { '1:1' => entry('P/A__1-1.png', frame('1:1', 'A')) })
        end
      end
    end

    context 'when an unchanged frame is missing its file' do
      it 'exports it again' do
        Dir.mktmpdir do |out|
          a = frame('1:1', 'A')
          seed_manifest(out, nodes: { '1:1' => entry('P/A__1-1.png', a) })
          client = stub_figma(pages: [page('P', a)])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('1 frames: 1 changed, 0 new, 0 unchanged')
          expect(client).to have_received(:image_urls).once
          expect(files_under(out)).to include('P/A__1-1.png')
        end
      end
    end

    context 'when an unchanged frame was renamed' do
      it 'renames the file without exporting it' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '1:1' => entry('Old page/Old__1-1.png', frame('1:1', 'Old')) })
          seed_file(out, 'Old page/Old__1-1.png', 'old image')
          client = stub_figma(pages: [page('New page', frame('1:1', 'New name'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(client).not_to have_received(:image_urls)
          expect(files_under(out)).to eq(['.figma-sync.json', 'New page/New name__1-1.png'])
          expect(File.read(File.join(out, 'New page/New name__1-1.png'))).to eq('old image')
          expect(manifest_paths(out)).to eq('1:1' => 'New page/New name__1-1.png')
        end
      end
    end

    context 'when an unchanged frame changed only the case of its name on a case-insensitive volume' do
      it 'fixes the case on disk without exporting it' do
        Dir.mktmpdir do |out|
          skip 'needs a case-insensitive volume for the system temp dir' unless case_insensitive?(out)
          seed_manifest(out, nodes: { '1:1' => entry('Mobile/Home__1-1.png', frame('1:1', 'Home')) })
          seed_file(out, 'Mobile/Home__1-1.png', 'old image')
          client = stub_figma(pages: [page('mobile', frame('1:1', 'home'))])

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(client).not_to have_received(:image_urls)
          expect(Dir.children(out).sort).to eq(%w[.figma-sync.json mobile])
          expect(Dir.children(File.join(out, 'mobile'))).to eq(['home__1-1.png'])
        end
      end
    end

    context 'when a text node six levels inside a frame changed' do
      it 'detects the change even though the structure fetch stops at depth 4' do
        Dir.mktmpdir do |out|
          nest = lambda do |text|
            leaf = { 'type' => 'TEXT', 'id' => '1:9', 'characters' => text }
            inner = %w[1:8 1:7 1:6 1:5 1:4].reduce(leaf) { |child, id| { 'type' => 'GROUP', 'id' => id, 'children' => [child] } }
            frame('1:1', 'Deep', children: [inner])
          end
          stub_figma(pages: [page('P', nest.call('Before'))], version: 'v1')
          run_cli('SimKey', '--token', 'tok', '--out', out)
          client = stub_figma(pages: [page('P', nest.call('After'))], version: 'v2')

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('1 frames: 1 changed, 0 new, 0 unchanged')
          expect(client).to have_received(:image_urls).once
        end
      end
    end

    context 'when there are more frames than one hashing request holds' do
      it 'hashes them 20 ids at a time' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('A', *(1..15).map { |i| frame("1:#{i}", "A#{i}") }),
                                      page('B', *(1..10).map { |i| frame("2:#{i}", "B#{i}") })])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(client).to have_received(:node_documents).twice
          expect(client).to have_received(:node_documents).with('SimKey', satisfy { _1.size == 20 })
          expect(client).to have_received(:node_documents).with('SimKey', satisfy { _1.size == 5 })
          expect(result.stderr).to include("Hashing 25 frames in 2 requests...\n  [1/2] hashed 20 frames\n")
        end
      end
    end

    context 'when --force is given' do
      it 'exports every frame regardless of hashes' do
        Dir.mktmpdir do |out|
          a = frame('1:1', 'A')
          seed_manifest(out, nodes: { '1:1' => entry('P/A__1-1.png', a) })
          seed_file(out, 'P/A__1-1.png', 'old image')
          client = stub_figma(pages: [page('P', a)])

          result = run_cli('SimKey', '--token', 'tok', '--out', out, '--force')

          expect(result.stderr).to include('1 frames: 0 changed, 0 new, 1 unchanged; re-exporting all (--force)')
          expect(client).to have_received(:image_urls).once
          expect(File.read(File.join(out, 'P/A__1-1.png'))).to eq('image from https://images.example/1:1')
        end
      end
    end

    context 'when the scale changed since the last run' do
      it 'exports every frame regardless of hashes' do
        Dir.mktmpdir do |out|
          a = frame('1:1', 'A')
          seed_manifest(out, scale: 1.0, nodes: { '1:1' => entry('P/A__1-1.png', a) })
          seed_file(out, 'P/A__1-1.png')
          client = stub_figma(pages: [page('P', a)])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('re-exporting all (scale or format changed)')
          expect(client).to have_received(:image_urls).once
        end
      end
    end

    context 'when a hashing request fails permanently for one frame' do
      it 'splits the request, exports that frame without a hash and hashes the rest' do
        Dir.mktmpdir do |out|
          frames = (1..4).map { |i| frame("1:#{i}", "F#{i}") }
          seed_manifest(out, nodes: frames.to_h { |f| [f['id'], entry("P/#{f['name']}__#{f['id'].tr(':', '-')}.png", f)] })
          frames.each { |f| seed_file(out, "P/#{f['name']}__#{f['id'].tr(':', '-')}.png") }
          client = stub_figma(pages: [page('P', *frames)])
          allow(client).to receive(:node_documents) do |_key, ids|
            raise FigmaSync::SyncError.new('GET /v1/files/SimKey/nodes returned HTTP 400', status: 400) if ids.include?('1:3')

            ids.to_h { |id| [id, frames.find { _1['id'] == id }] }
          end

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(client).to have_received(:node_documents).with('SimKey', %w[1:1 1:2 1:3 1:4])
          expect(client).to have_received(:node_documents).with('SimKey', %w[1:3])
          expect(result.stderr).to include('warning: could not hash 1:3 (GET /v1/files/SimKey/nodes returned HTTP 400); ' \
                                           'exporting them without a hash',
                                           '4 frames: 1 changed, 0 new, 3 unchanged')
          expect(client).to have_received(:image_urls).once.with('SimKey', %w[1:3], fmt: 'png', scale: 2.0)
          expect(read_manifest(out)).to include('version' => 'v2')
          expect(read_manifest(out)['nodes']['1:3']).to eq('path' => 'P/F3__1-3.png', 'hash' => nil)
          expect(result.stderr).to include("  [1/1] hashed 3 of 4 frames\n")
        end
      end
    end

    context 'when a hashing request keeps being rate limited' do
      it 'stops with exit 1 after the retries and writes nothing' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', frame('1:1', 'A'), frame('1:2', 'B'))])
          allow(client).to receive(:node_documents)
            .and_raise(FigmaSync::TransientError.new('GET /v1/files/SimKey/nodes returned HTTP 429', status: 429))
          waits = []
          allow(described_class).to receive(:sleep) { |seconds| waits << seconds }

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(waits).to eq([5, 15, 45])
          expect(client).to have_received(:node_documents).exactly(4).times
          expect(result.stderr).to end_with('figma-sync: Figma is rate limiting frame hashing (GET /v1/files/SimKey/nodes ' \
                                            "returned HTTP 429); stopped without changing anything, the next run will retry\n")
          expect(client).not_to have_received(:image_urls)
          expect(Dir.children(out)).to eq([])
        end
      end
    end

    context 'when one frame in a hashing request always fails with a server error' do
      it 'splits without retrying and spends the retries only on that frame' do
        Dir.mktmpdir do |out|
          frames = (1..4).map { |i| frame("1:#{i}", "F#{i}") }
          client = stub_figma(pages: [page('P', *frames)])
          calls = []
          allow(client).to receive(:node_documents) do |_key, ids|
            calls << ids
            raise FigmaSync::TransientError.new('GET /v1/files/SimKey/nodes returned HTTP 500', status: 500) if ids.include?('1:3')

            ids.to_h { |id| [id, frames.find { _1['id'] == id }] }
          end
          waits = []
          allow(described_class).to receive(:sleep) { |seconds| waits << seconds }

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(calls).to eq([%w[1:1 1:2 1:3 1:4], %w[1:1 1:2], %w[1:3 1:4], %w[1:3], %w[1:3], %w[1:3], %w[1:3], %w[1:4]])
          expect(waits).to eq([5, 15, 45])
          expect(result.stderr).to include("  [1/1] hashed 3 of 4 frames\n")
        end
      end
    end

    context 'when every hashing request fails' do
      it 'stops requesting after three failures and exports the rest without hashes' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', *(1..60).map { |i| frame("1:#{i}", "F#{i}") })])
          allow(client).to receive(:node_documents)
            .and_raise(FigmaSync::TransientError.new('GET /v1/files/SimKey/nodes returned HTTP 503', status: 503))
          waits = []
          allow(described_class).to receive(:sleep) { |seconds| waits << seconds }

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(client).to have_received(:node_documents).exactly(17).times
          expect(waits).to eq([5, 15, 45] * 3)
          expect(result.stderr).to include('warning: stopped hashing after 3 failed requests; ' \
                                           "57 remaining frame(s) will be exported without a hash\n",
                                           "  [1/3] hashed 0 of 20 frames\n", '60 frames: 0 changed, 60 new, 0 unchanged')
          expect(result.stderr).not_to include('[2/3] hashed')
          expect(files_under(out).size).to eq(61)
        end
      end
    end

    context 'when a multi-frame hashing request times out' do
      it 'splits it without waiting' do
        Dir.mktmpdir do |out|
          frames = [frame('1:1', 'A'), frame('1:2', 'B')]
          client = stub_figma(pages: [page('P', *frames)])
          calls = []
          allow(client).to receive(:node_documents) do |_key, ids|
            calls << ids
            if ids.size > 1
              begin
                raise Net::ReadTimeout
              rescue Net::ReadTimeout
                raise FigmaSync::TransientError, 'api.figma.com: Net::ReadTimeout (Net::ReadTimeout)'
              end
            end
            ids.to_h { |id| [id, frames.find { _1['id'] == id }] }
          end
          waits = []
          allow(described_class).to receive(:sleep) { |seconds| waits << seconds }

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(calls).to eq([%w[1:1 1:2], %w[1:1], %w[1:2]])
          expect(waits).to eq([])
          expect(result.stderr).to include("  [1/1] hashed 2 frames\n")
        end
      end
    end

    context 'when a hashing request is rejected for the token' do
      it 'stops the run with exit 1' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))])
          allow(client).to receive(:node_documents).and_raise(FigmaSync::AuthError, 'Figma API returned HTTP 403 (Invalid token)')

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(client).not_to have_received(:image_urls)
        end
      end
    end

    context 'when a later hashing request is rejected for the token' do
      it 'exits 1 without writing any file or manifest' do
        Dir.mktmpdir do |out|
          frames = (1..25).map { |i| frame("1:#{i}", "F#{i}") }
          client = stub_figma(pages: [page('P', *frames)])
          allow(client).to receive(:node_documents) do |_key, ids|
            raise FigmaSync::AuthError, 'Figma API returned HTTP 403 (Invalid token)' if ids.size < 20

            ids.to_h { |id| [id, frames.find { _1['id'] == id }] }
          end

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr).to end_with("figma-sync: Figma API returned HTTP 403 (Invalid token)\n")
          expect(client).to have_received(:node_documents).twice
          expect(Dir.children(out)).to eq([])
        end
      end
    end

    context 'when a frame is nested more than 100 levels deep' do
      it 'hashes and exports it' do
        Dir.mktmpdir do |out|
          deep = (1..150).reduce({ 'type' => 'TEXT', 'id' => 'leaf' }) { |child, i| { 'type' => 'GROUP', 'id' => "g#{i}", 'children' => [child] } }
          stub_figma(pages: [page('P', frame('1:1', 'Deep', children: [deep]))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(read_manifest(out)['nodes']['1:1']['hash']).to match(/\A\h{64}\z/)
        end
      end
    end

    context 'when --dry-run is given' do
      it 'prints the breakdown, the frames to export and the renames' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '1:1' => entry('P/A__1-1.png', frame('1:1', 'A')),
                                      '1:2' => entry('P/B__1-2.png', frame('1:2', 'B')),
                                      '1:3' => entry('P/Old__1-3.png', frame('1:3', 'C')) })
          %w[P/A__1-1.png P/B__1-2.png P/Old__1-3.png].each { seed_file(out, _1) }
          client = stub_figma(pages: [page('P', frame('1:1', 'A'), frame('1:2', 'B', opacity: 0.4),
                                           frame('1:3', 'C'), frame('1:4', 'D'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out, '--dry-run')

          expect(result.stdout).to eq("Output: #{out}\n4 frames: 1 changed, 1 new, 2 unchanged\n" \
                                      "Would export 2 frames in 1 batches\n  P/B__1-2.png  (changed)\n  P/D__1-4.png  (new)\n" \
                                      "Would rename 1 unchanged file(s)\n  - P/Old__1-3.png  ->  P/C__1-3.png\n" \
                                      "Would delete 0 stale file(s) for removed frames\n")
          expect(client).not_to have_received(:image_urls)
          expect(files_under(out)).to include('P/Old__1-3.png')
        end
      end
    end
  end
end
