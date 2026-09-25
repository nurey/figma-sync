# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FigmaSync do
  describe '.pages_with_frames' do
    context 'when a page has frames at the top level' do
      it 'collects them with their page name' do
        document = { 'children' => [page('Home', frame('1:1', 'Hero'), frame('1:2', 'Footer'))] }

        pages = described_class.pages_with_frames(document)

        expect(pages).to eq([['Home', [{ id: '1:1', name: 'Hero', page: 'Home' },
                                       { id: '1:2', name: 'Footer', page: 'Home' }]]])
      end
    end

    context 'when frames sit inside nested sections' do
      it 'collects them recursively under the page' do
        document = { 'children' => [page('P', section('Outer', frame('1:1', 'A'), section('Inner', frame('1:2', 'B'))))] }

        pages = described_class.pages_with_frames(document)

        expect(pages.first.last.map { |f| f[:id] }).to eq(%w[1:1 1:2])
      end
    end

    context 'when the page holds nodes that are not frames or sections' do
      it 'skips them' do
        others = %w[TEXT INSTANCE COMPONENT COMPONENT_SET GROUP RECTANGLE].map.with_index do |type, i|
          { 'type' => type, 'id' => "9:#{i}", 'name' => type, 'children' => [frame("8:#{i}", 'nested in a non-section')] }
        end
        document = { 'children' => [page('P', *others, frame('1:1', 'Kept'))] }

        pages = described_class.pages_with_frames(document)

        expect(pages.first.last.map { |f| f[:id] }).to eq(%w[1:1])
      end
    end

    context 'when frames are hidden or fully transparent' do
      it 'skips them' do
        document = { 'children' => [page('P', frame('1:1', 'Shown'), frame('1:2', 'Hidden', visible: false),
                                          frame('1:3', 'Clear', opacity: 0), frame('1:4', 'Faint', opacity: 0.2))] }

        pages = described_class.pages_with_frames(document)

        expect(pages.first.last.map { |f| f[:id] }).to eq(%w[1:1 1:4])
      end
    end

    context 'when sections are hidden or fully transparent' do
      it 'skips every frame inside them' do
        document = { 'children' => [page('P', section('Hidden', frame('1:1', 'A'), visible: false),
                                          section('Clear', frame('1:2', 'B'), opacity: 0.0),
                                          section('Shown', frame('1:3', 'C')))] }

        pages = described_class.pages_with_frames(document)

        expect(pages.first.last.map { |f| f[:id] }).to eq(%w[1:3])
      end
    end

    context 'when a page name is only dashes and whitespace' do
      it 'skips it as a separator' do
        document = { 'children' => [page('---', frame('1:1', 'A')), page(' - - ', frame('1:2', 'B')),
                                    page('', frame('1:3', 'C')), page('-Drafts', frame('1:4', 'D'))] }

        pages = described_class.pages_with_frames(document)

        expect(pages.map(&:first)).to eq(['-Drafts'])
      end
    end

    context 'when a top-level child is not a CANVAS' do
      it 'skips it' do
        document = { 'children' => [{ 'type' => 'FRAME', 'id' => '1:1', 'name' => 'stray' }, page('P')] }

        expect(described_class.pages_with_frames(document)).to eq([['P', []]])
      end
    end

    context 'when a section is deeper than the fetched depth' do
      it 'warns that its frames are not exported' do
        document = { 'children' => [page('P', { 'type' => 'SECTION', 'id' => '5:5', 'name' => 'Deep' })] }

        expect { described_class.pages_with_frames(document) }
          .to output(/section "Deep" on "P" is nested deeper than the 4 levels fetched/).to_stderr
      end
    end
  end

  describe '.make_batches' do
    context 'when pages have more frames than one batch' do
      it 'splits into batches of 20 that never span pages' do
        pages = [['A', (1..25).map { |i| { id: "1:#{i}", name: "A#{i}", page: 'A' } }],
                 ['B', (1..3).map { |i| { id: "2:#{i}", name: "B#{i}", page: 'B' } }]]

        batches = described_class.make_batches(pages, 'png', nil)

        expect(batches.map { |name, items| [name, items.size] }).to eq([['A', 20], ['A', 5], ['B', 3]])
        expect(batches.first.last.first).to eq(['1:1', 'A/A1__1-1.png'])
      end
    end

    context 'when a limit is given' do
      it 'stops after that many frames across pages' do
        pages = [['A', [{ id: '1:1', name: 'a', page: 'A' }]],
                 ['B', [{ id: '2:1', name: 'b', page: 'B' }, { id: '2:2', name: 'c', page: 'B' }]],
                 ['C', [{ id: '3:1', name: 'd', page: 'C' }]]]

        batches = described_class.make_batches(pages, 'png', 2)

        expect(batches.flat_map { |_, items| items.map(&:first) }).to eq(%w[1:1 2:1])
      end
    end
  end
end
