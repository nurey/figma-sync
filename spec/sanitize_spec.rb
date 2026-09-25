# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FigmaSync do
  describe '.sanitize' do
    context 'when the name contains / or :' do
      it 'replaces them with -' do
        expect(described_class.sanitize('Checkout / step 1: address')).to eq('Checkout - step 1- address')
      end
    end

    context 'when the name contains runs of whitespace' do
      it 'collapses them to one space and trims the ends' do
        expect(described_class.sanitize("  Home \t\n  page  ")).to eq('Home page')
      end
    end

    context 'when the name starts with dots' do
      it 'strips them so the result is not a hidden file' do
        expect(described_class.sanitize('.archive')).to eq('archive')
        expect(described_class.sanitize('. . notes')).to eq('notes')
      end
    end

    context 'when the name is a path traversal' do
      it 'cannot produce a parent-directory segment' do
        expect(described_class.sanitize('../../etc')).to eq('-..-etc')
      end
    end

    context 'when nothing is left after cleaning' do
      it 'falls back to untitled' do
        expect(described_class.sanitize('..')).to eq('untitled')
        expect(described_class.sanitize('   ')).to eq('untitled')
        expect(described_class.sanitize('')).to eq('untitled')
      end
    end

    context 'when the name is longer than 100 bytes of ASCII' do
      it 'truncates to 100 bytes' do
        expect(described_class.sanitize('a' * 150)).to eq('a' * 100)
      end
    end

    context 'when truncation would split a multibyte character' do
      it 'drops the partial character and stays under 100 bytes' do
        sanitized = described_class.sanitize("a#{"\u{1F600}" * 99}")

        expect(sanitized.bytesize).to eq(97)
        expect(sanitized).to be_valid_encoding
        expect(sanitized).to eq("a#{"\u{1F600}" * 24}")
      end
    end
  end

  describe '.relative_path' do
    it 'builds <page>/<frame>__<id>.<format> from sanitized names' do
      path = described_class.relative_path({ id: '12:34', name: 'Home: v2', page: 'Mobile/iOS' }, 'svg')

      expect(path).to eq('Mobile-iOS/Home- v2__12-34.svg')
    end
  end
end
