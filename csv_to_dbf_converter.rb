# frozen_string_literal: true

require 'csv'
require 'date'
require 'fileutils'

# --- Модуль оформления (ANSI цвета и стили) ---
module UI
  # Цвета включаем только в терминале, чтобы не засорять логи и пайпы escape-кодами.
  ANSI = $stdout.tty?

  CLEAR   = ANSI ? "\e[0m" : ''
  BOLD    = ANSI ? "\e[1m" : ''
  GREEN   = ANSI ? "\e[32m" : ''
  YELLOW  = ANSI ? "\e[33m" : ''
  CYAN    = ANSI ? "\e[36m" : ''
  RED     = ANSI ? "\e[31m" : ''
  GRAY    = ANSI ? "\e[90m" : ''

  def self.banner
    puts "#{CYAN}╔══════════════════════════════════════════════════════════╗#{CLEAR}"
    puts "#{CYAN}║#{BOLD}              КОНВЕРТЕР CSV ➔ DBF (Win-1251)              #{CLEAR}#{CYAN}║#{CLEAR}"
    puts "#{CYAN}╚══════════════════════════════════════════════════════════╝#{CLEAR}\n\n"
  end

  def self.box(text, color = CYAN)
    puts "#{color}──────────────────────────────────────────────────────────#{CLEAR}"
    puts " #{text}"
    puts "#{color}──────────────────────────────────────────────────────────#{CLEAR}\n"
  end

  def self.success(msg) = puts("  #{GREEN}✔#{CLEAR}  #{msg}")
  def self.error(msg) = puts("  #{RED}✖#{CLEAR}  #{msg}")
  def self.skip(msg) = puts("  #{YELLOW}↷#{CLEAR}  #{msg}")
  def self.info(msg) = puts("  #{CYAN}ℹ#{CLEAR}  #{msg}")
end

# --- Каталоги (рядом со скриптом) ---
BASE_DIR      = File.dirname(File.expand_path(__FILE__))
CSV_DIR       = File.join(BASE_DIR, 'CSV')
CONVERTED_DIR = File.join(BASE_DIR, 'Converted_CSV')
DBF_DIR       = File.join(BASE_DIR, 'DBF')
LOG_FILE      = File.join(BASE_DIR, 'conversion.log')
ARCHIVE_DIR   = File.join(BASE_DIR, 'Logs')

def ensure_output_dirs
  FileUtils.mkdir_p(CONVERTED_DIR)
  FileUtils.mkdir_p(DBF_DIR)
end

# Возвращает свободный путь в каталоге dir, добавляя _1, _2, ... при коллизии.
def unique_path(dir, filename)
  ext  = File.extname(filename)
  base = File.basename(filename, ext)
  candidate = File.join(dir, filename)
  counter = 1
  while File.exist?(candidate)
    candidate = File.join(dir, "#{base}_#{counter}#{ext}")
    counter += 1
  end
  candidate
end

# --- Журнал конвертаций ---
# Формат строки: epoch\tstatus\tимя.csv\tdetail (detail = .dbf, причина или сообщение).

# Раз в месяц (при первом запуске/записи в новом месяце) убирает прошлый журнал в Logs/.
# Возвращает путь архива, если он был создан.
def archive_log_if_needed
  return nil unless File.file?(LOG_FILE)

  log_month = File.mtime(LOG_FILE).strftime('%Y-%m')
  return nil if log_month == Time.now.strftime('%Y-%m')

  FileUtils.mkdir_p(ARCHIVE_DIR)
  archive = unique_path(ARCHIVE_DIR, "conversion_#{log_month}.log")
  FileUtils.mv(LOG_FILE, archive)
  archive
rescue StandardError
  nil
end

def log_conversion(status, name, detail)
  archive_log_if_needed
  File.open(LOG_FILE, 'a:UTF-8') do |f|
    f.puts "#{Time.now.to_i}\t#{status}\t#{name}\t#{detail}"
  end
rescue StandardError
  nil
end

# Отчёт учитывает и текущий журнал, и архивы (чтобы «за месяц» не терял данные).
def log_files
  files = []
  files << LOG_FILE if File.file?(LOG_FILE)
  files.concat(Dir.glob(File.join(ARCHIVE_DIR, '*.log')))
  files
end

def read_log_file(path)
  File.foreach(path, chomp: true, encoding: 'UTF-8').filter_map do |line|
    epoch, status, name, detail = line.split("\t", 4)
    next if epoch.nil? || status.nil? || name.nil?

    { time: Time.at(epoch.to_i), status: status.to_sym, name: name, detail: detail.to_s }
  end
rescue StandardError
  []
end

def read_conversion_log
  log_files.flat_map { |path| read_log_file(path) }
rescue StandardError
  []
end

# --- Определение кодировки исходного CSV ---
def detect_encoding(bytes)
  return Encoding::UTF_8    if bytes.start_with?("\xEF\xBB\xBF".b)
  return Encoding::UTF_16LE if bytes.start_with?("\xFF\xFE".b)
  return Encoding::UTF_16BE if bytes.start_with?("\xFE\xFF".b)
  return Encoding::UTF_8    if bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?

  sample = bytes[0, 4096].to_s
  if sample.include?("\x00".b)
    even_nuls = sample.bytes.each_with_index.count { |b, i| i.even? && b.zero? }
    odd_nuls  = sample.bytes.each_with_index.count { |b, i| i.odd? && b.zero? }
    return Encoding::UTF_16BE if even_nuls > odd_nuls
    return Encoding::UTF_16LE if odd_nuls.positive?
  end

  detect_legacy_encoding(sample)
end

# Однобайтовые кодировки всегда "валидны", поэтому выбираем лучшую по эвристике.
def detect_legacy_encoding(sample)
  best = nil
  best_score = -Float::INFINITY
  [Encoding::Windows_1251, Encoding::KOI8_R, Encoding::CP866].each do |enc|
    text = sample.dup.force_encoding(enc)
    next unless text.valid_encoding?

    score = legacy_score(text)
    if score > best_score
      best_score = score
      best = enc
    end
  end
  best || Encoding::Windows_1251
end

# Доля осмысленных (печатных/кириллических) символов минус доля мусора.
def legacy_score(text)
  chars = text.each_char.to_a
  return 0.0 if chars.empty?

  printable = 0
  cyrillic  = 0
  junk      = 0
  chars.each do |ch|
    cp = ch.ord
    if cp < 0x20 && ![9, 10, 13].include?(cp)
      junk += 1
    elsif cp.between?(0x0410, 0x044F) || cp == 0x0401 || cp == 0x0451
      cyrillic += 1
      printable += 1
    elsif cp >= 0x20
      printable += 1
    end
  end

  size = chars.size.to_f
  (printable / size) - (junk / size) + ((cyrillic / size) * 0.5)
end

def strip_bom(bytes, encoding)
  case encoding
  when Encoding::UTF_8    then bytes.delete_prefix("\xEF\xBB\xBF".b)
  when Encoding::UTF_16LE then bytes.delete_prefix("\xFF\xFE".b)
  when Encoding::UTF_16BE then bytes.delete_prefix("\xFE\xFF".b)
  else bytes
  end
end

# Читает CSV в любой кодировке. Возвращает [текст_в_UTF-8, обнаруженная_кодировка].
def decode_csv(path)
  raw = File.binread(path)
  encoding = detect_encoding(raw)
  raw = strip_bom(raw, encoding)
  raw.force_encoding(encoding)
  [raw.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: ''), encoding]
end

# Перекодирует значение в windows-1251 (для 1С). Неподдерживаемые символы удаляются.
def to_cp1251(value)
  value.to_s.strip.encode('cp1251', invalid: :replace, undef: :replace, replace: '').b
rescue StandardError
  value.to_s.b
end

def dbf_field_name(header, idx)
  name = to_cp1251(header)
  name = name[0, 10]
  name = "COL_#{idx}".b if name.empty?
  name
end

# --- Логика генерации DBF ---
def save_as_dbf3(dbf_path, headers, data_rows)
  num_records = data_rows.size

  col_lengths = headers.each_with_index.map do |_, idx|
    max_len = data_rows.map { |r| r[idx].bytesize }.max || 0
    [[max_len, 1].max, 254].min
  end

  header_size = 32 + (headers.size * 32) + 1
  record_size = 1 + col_lengths.sum

  File.open(dbf_path, 'wb') do |f|
    now = Date.today

    header = [
      0x03,
      now.year % 100,
      now.month,
      now.day,
      num_records,
      header_size,
      record_size
    ].pack('CCCCVvv') + ("\x00" * 17) + "\xC9".b + ("\x00" * 2)

    f.write(header)

    headers.each_with_index do |h, idx|
      field_name   = h.to_s.b[0, 10].ljust(11, "\x00".b)
      field_length = col_lengths[idx]

      field_desc = [
        field_name,
        'C',
        0,
        field_length,
        0
      ].pack('a11a1VCC') + ("\x00" * 14)

      f.write(field_desc)
    end

    f.write("\x0D")

    data_rows.each do |row|
      f.write(' ')
      row.each_with_index do |val_bytes, idx|
        field_length = col_lengths[idx]
        f.write(val_bytes[0, field_length].ljust(field_length, ' '))
      end
    end

    f.write("\x1A")
  end
end

# --- Конвертация одного CSV ---
# Возвращает хэш со статусом: :ok, :skipped или :error.
def process_csv(csv_path, index: nil, total: nil)
  file_name = File.basename(csv_path)
  text, encoding = decode_csv(csv_path)

  prefix = index ? "[#{index}/#{total}] " : ''
  print "  #{prefix}#{UI::CYAN}#{file_name}#{UI::CLEAR} (#{encoding.name}) ... "

  rows = CSV.parse(
    text,
    headers: true,
    col_sep: ';',
    liberal_parsing: true
  )

  if rows.empty? || rows.headers.nil?
    puts "#{UI::YELLOW}пропущено: нет заголовков#{UI::CLEAR}"
    log_conversion(:skipped, file_name, 'нет заголовков')
    return { status: :skipped, name: file_name, reason: 'нет заголовков' }
  end

  headers = rows.headers.each_with_index.map do |h, idx|
    dbf_field_name(h, idx)
  end

  data_rows = rows.map do |row|
    headers.each_index.map { |idx| to_cp1251(row[idx]) }
  end

  base = file_name.sub(/\.csv\z/i, '')
  dbf_path = unique_path(DBF_DIR, "#{base}.dbf")
  save_as_dbf3(dbf_path, headers, data_rows)

  converted_path = unique_path(CONVERTED_DIR, file_name)
  FileUtils.mv(csv_path, converted_path)

  puts "#{UI::GREEN}✔#{UI::CLEAR} строк: #{rows.size} #{UI::GRAY}➔#{UI::CLEAR} DBF/#{File.basename(dbf_path)}"
  log_conversion(:ok, file_name, File.basename(dbf_path))

  {
    status: :ok,
    name: file_name,
    dbf: File.basename(dbf_path),
    converted: File.basename(converted_path)
  }
rescue StandardError => e
  puts "#{UI::RED}✖#{UI::CLEAR} #{e.message}"
  log_conversion(:error, file_name, e.message)
  { status: :error, name: file_name, message: e.message }
end

# --- Пункты меню ---
def csv_files_in_queue
  Dir.glob(File.join(CSV_DIR, '*.csv'), File::FNM_CASEFOLD)
end

def convert_all
  unless Dir.exist?(CSV_DIR)
    FileUtils.mkdir_p(CSV_DIR)
    UI.box("Каталог #{UI::BOLD}#{CSV_DIR}#{UI::CLEAR} не был найден и создан.")
    UI.skip('Каталог пуст. Скопируйте в него CSV-файлы для конвертации.')
    return
  end

  csv_files = csv_files_in_queue
  if csv_files.empty?
    UI.skip("Каталог #{UI::BOLD}#{CSV_DIR}#{UI::CLEAR} пуст. " \
            'Скопируйте в него файлы, которые нужно конвертировать.')
    return
  end

  UI.info("Найдено CSV файлов: #{UI::BOLD}#{csv_files.size}#{UI::CLEAR}\n\n")

  results = csv_files.each_with_index.map do |csv_path, i|
    process_csv(csv_path, index: i + 1, total: csv_files.size)
  end

  print_summary(results)
end

def print_summary(results)
  ok      = results.select { |r| r[:status] == :ok }
  skipped = results.select { |r| r[:status] == :skipped }
  errors  = results.select { |r| r[:status] == :error }

  puts ''
  unless ok.empty?
    UI.box("Сконвертировано: #{UI::BOLD}#{ok.size}#{UI::CLEAR}", UI::GREEN)
    ok.each { |r| UI.success("#{r[:name]} #{UI::GRAY}➔#{UI::CLEAR} DBF/#{r[:dbf]}") }
  end

  unless skipped.empty?
    UI.box("Пропущено: #{UI::BOLD}#{skipped.size}#{UI::CLEAR}", UI::YELLOW)
    skipped.each { |r| UI.skip("#{r[:name]} — #{r[:reason]}") }
  end

  unless errors.empty?
    UI.box("Ошибок: #{UI::BOLD}#{errors.size}#{UI::CLEAR}", UI::RED)
    errors.each { |r| UI.error("#{r[:name]} — #{r[:message]}") }
  end
end

def resolve_csv_path(input)
  return input if File.file?(input)

  [File.join(CSV_DIR, input), File.join(CSV_DIR, "#{input}.csv")].find { |p| File.file?(p) }
end

def convert_one
  print "#{UI::BOLD}Укажите имя файла или полный путь к нему#{UI::GRAY} [Enter = отмена]#{UI::CLEAR}: "
  input = $stdin.gets&.chomp.to_s.strip.delete('"')

  if input.empty?
    UI.skip('Операция отменена.')
    return
  end

  csv_path = resolve_csv_path(input)
  if csv_path.nil?
    UI.error("Файл не найден: #{input}")
    return
  end

  unless File.extname(csv_path).casecmp('.csv').zero?
    UI.error('Указанный файл не является CSV-файлом.')
    return
  end

  result = process_csv(csv_path)

  puts ''
  case result[:status]
  when :ok
    UI.box("Файл сконвертирован: #{UI::BOLD}#{result[:name]}#{UI::CLEAR} " \
           "#{UI::GRAY}➔#{UI::CLEAR} DBF/#{result[:dbf]}", UI::GREEN)
  when :skipped
    UI.skip("Файл не сконвертирован: #{result[:name]} — #{result[:reason]}")
  else
    UI.error("Файл не сконвертирован: #{result[:name]} — #{result[:message]}")
  end
end

def conversion_report
  entries = read_conversion_log
  if entries.empty?
    UI.skip('Журнал пуст. Сначала выполните конвертацию.')
    return
  end

  now = Time.now
  UI.box("#{UI::BOLD}ОТЧЕТ О КОНВЕРТАЦИИ#{UI::CLEAR}")
  [['за 1 день', 86_400], ['за неделю', 7 * 86_400], ['за месяц', 30 * 86_400]].each do |label, seconds|
    period  = entries.select { |e| e[:time] >= now - seconds }
    ok      = period.count { |e| e[:status] == :ok }
    skipped = period.count { |e| e[:status] == :skipped }
    errors  = period.count { |e| e[:status] == :error }

    puts "  #{UI::BOLD}#{label}:#{UI::CLEAR} " \
         "сконвертировано #{UI::GREEN}#{ok}#{UI::CLEAR}, " \
         "пропущено #{UI::YELLOW}#{skipped}#{UI::CLEAR}, " \
         "ошибок #{UI::RED}#{errors}#{UI::CLEAR}"
  end

  total_ok      = entries.count { |e| e[:status] == :ok }
  total_skipped = entries.count { |e| e[:status] == :skipped }
  total_errors  = entries.count { |e| e[:status] == :error }

  puts ''
  UI.box("Всего в журнале: #{UI::BOLD}#{entries.size}#{UI::CLEAR} " \
         "(успешно #{total_ok}, пропущено #{total_skipped}, ошибок #{total_errors})")
  UI.info("Журнал: #{UI::BOLD}#{LOG_FILE}#{UI::CLEAR}")
  archived = Dir.glob(File.join(ARCHIVE_DIR, '*.log')).size
  UI.info("Архив: #{UI::BOLD}#{ARCHIVE_DIR}#{UI::CLEAR} (#{archived} шт.)") if archived.positive?
end

def show_menu
  UI.box("#{UI::BOLD}ГЛАВНОЕ МЕНЮ#{UI::CLEAR}")
  puts "  #{UI::GRAY}CSV:#{UI::CLEAR}           #{CSV_DIR} " \
       "#{UI::BOLD}(#{csv_files_in_queue.size} шт.)#{UI::CLEAR}"
  puts "  #{UI::GRAY}DBF:#{UI::CLEAR}           #{DBF_DIR}"
  puts "  #{UI::GRAY}Converted_CSV:#{UI::CLEAR} #{CONVERTED_DIR}"
  puts ''
  puts "  #{UI::BOLD}1#{UI::CLEAR}. Конвертировать все файлы"
  puts "  #{UI::BOLD}2#{UI::CLEAR}. Конвертировать конкретный файл"
  puts "  #{UI::BOLD}3#{UI::CLEAR}. Отчет"
  puts "  #{UI::BOLD}4#{UI::CLEAR}. Завершить работу программы"
  puts ''
  print "#{UI::BOLD}Ваш выбор#{UI::CLEAR}: "
end

# --- Основной процесс ---

$stdout.sync = true
ensure_output_dirs
UI.banner

if (archive = archive_log_if_needed)
  UI.info("Журнал за прошлый месяц перемещён в архив: #{File.basename(archive)}")
end

loop do
  show_menu
  choice = $stdin.gets&.chomp.to_s.strip
  puts ''

  case choice
  when '1'
    convert_all
  when '2'
    convert_one
  when '3'
    conversion_report
  when '4'
    break
  else
    UI.error('Неверный пункт меню. Введите 1, 2, 3 или 4.')
  end

  puts ''
  puts "#{UI::GRAY}Нажмите Enter, чтобы продолжить...#{UI::CLEAR}"
  $stdin.gets
end

puts ''
UI.box('Работа программы завершена!', UI::GREEN)
puts "#{UI::GRAY}Нажмите Enter, чтобы закрыть окно...#{UI::CLEAR}"
$stdin.gets
