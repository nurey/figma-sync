# frozen_string_literal: true

module FigmaSyncHelpers
  CliResult = Struct.new(:code, :stdout, :stderr)
  SPEC_TMP = File.expand_path('../tmp', __dir__)

  def run_cli(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    $stdout = stdout
    $stderr = stderr
    code = begin
      FigmaSync.main(argv)
    rescue SystemExit => e
      e.status
    end
    CliResult.new(code, stdout.string, stderr.string)
  ensure
    $stdout = STDOUT
    $stderr = STDERR
  end

  def frame(id, name, **attrs)
    { 'type' => 'FRAME', 'id' => id, 'name' => name, **attrs.transform_keys(&:to_s) }
  end

  def section(name, *children, **attrs)
    { 'type' => 'SECTION', 'id' => "s-#{name}", 'name' => name, 'children' => children, **attrs.transform_keys(&:to_s) }
  end

  def page(name, *children)
    { 'type' => 'CANVAS', 'id' => "p-#{name}", 'name' => name, 'children' => children }
  end

  def stub_figma(pages:, version: 'v2', images: {})
    client = instance_double(FigmaSync::Client)
    meta = { 'name' => 'Sim file', 'version' => version, 'lastModified' => '2026-09-25T00:00:00Z' }
    allow(client).to receive(:get_file).with('SimKey', depth: 1).and_return(meta)
    allow(client).to receive(:get_file).with('SimKey', depth: 4)
                                       .and_return(meta.merge('document' => { 'children' => pages }))
    allow(client).to receive(:image_urls) do |_key, ids, **|
      ids.to_h { |id| [id, images.fetch(id, "https://images.example/#{id}")] }
    end
    allow(client).to receive(:download) do |url, dest|
      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, "image from #{url}")
    end
    allow(FigmaSync::Client).to receive(:new).with('tok').and_return(client)
    client
  end

  def seed_manifest(out, nodes:, version: 'v1', file_key: 'SimKey', scale: 2.0, format: 'png')
    FileUtils.mkdir_p(out)
    manifest = { 'fileKey' => file_key, 'version' => version, 'scale' => scale, 'format' => format, 'nodes' => nodes }
    File.write(File.join(out, '.figma-sync.json'), JSON.generate(manifest))
  end

  def seed_file(out, rel, body = 'old image')
    path = File.join(out, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def read_manifest(out)
    JSON.parse(File.read(File.join(out, '.figma-sync.json')))
  end

  def files_under(out)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: out).reject { |p| p.end_with?('.') || File.directory?(File.join(out, p)) }.sort
  end

  def case_insensitive?(dir)
    probe = File.join(dir, 'CaseProbe')
    File.write(probe, '')
    File.exist?(File.join(dir, 'caseprobe'))
  ensure
    FileUtils.rm_f(probe)
  end

  def spec_tmpdir(&)
    FileUtils.mkdir_p(SPEC_TMP)
    Dir.mktmpdir('figma-sync-', SPEC_TMP, &)
  end

  def serve_http(*responses)
    server = TCPServer.new('127.0.0.1', 0)
    requests = []
    thread = Thread.new do
      responses.each do |status, headers, body|
        socket = server.accept
        line = socket.gets.to_s.chomp
        request_headers = {}
        while (header = socket.gets) && header != "\r\n"
          name, value = header.chomp.split(': ', 2)
          request_headers[name.downcase] = value
        end
        requests << { line:, headers: request_headers }
        extra = headers.map { |name, value| "#{name}: #{value}\r\n" }.join
        socket.write("HTTP/1.1 #{status} Canned\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n#{extra}\r\n#{body}")
        socket.close
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}", requests
  ensure
    thread&.kill
    server&.close
  end

  def closed_port
    TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
  end
end
