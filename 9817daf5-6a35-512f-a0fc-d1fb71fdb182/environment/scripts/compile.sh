#!/bin/bash -eu
# Stage a sanitizer build of the library.
#
#   compile.sh <variant> [source_dir] [staged_dir]
#
# Four binaries land in the staged directory, each instrumented with
# AddressSanitizer and linked against libFuzzer:
#   arrow-ipc-stream-fuzz   reads one IPC stream
#   arrow-ipc-file-fuzz     reads one IPC file
#   parquet-arrow-fuzz      reads one Parquet file
#   roundtrip               the behaviour probe the regression suite reads
#
# Building through the canonical /opt/arrow-src symlink and /opt/arrow-bld
# scratch directory keeps every compiler path identical across invocations, so
# ccache warm from image build time recompiles only the translation units a
# patch actually modified.
set -euo pipefail

VARIANT="${1:-patched}"
SRC_DIR="$(cd "${2:-/src/arrow}" && pwd)"
OUT_DIR="${3:-/out/${VARIANT}}"
BLD=/opt/arrow-bld
CANON_SRC=/opt/arrow-src
trap 'rm -rf "$BLD" "$CANON_SRC"' EXIT

rm -rf "$OUT_DIR" "$BLD" "$CANON_SRC"
mkdir -p "$OUT_DIR" "$BLD" /opt/ccache
ln -s "$SRC_DIR" "$CANON_SRC"

export CC=clang CXX=clang++
unset CFLAGS CXXFLAGS LDFLAGS LIB_FUZZING_ENGINE
# Normalize locale: Python's PEP 538 coercion injects LC_CTYPE=C.UTF-8 into
# child processes, and clang's ccache hash is locale-sensitive, so a build
# launched from pytest would otherwise miss every entry the image build made.
export LC_ALL=C
unset LANG LC_CTYPE
export CCACHE_DIR="${CCACHE_DIR:-/opt/ccache}"
export CCACHE_BASEDIR="$SRC_DIR"
export CCACHE_NOHASHDIR=1 CCACHE_SLOPPINESS=include_file_mtime,include_file_ctime

FLAGS="-O1 -g -fno-omit-frame-pointer -Wno-deprecated-declarations -fdebug-prefix-map=${CANON_SRC}=/src/arrow"

cd "$BLD"

cmake "$CANON_SRC/cpp" -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS" \
  -DARROW_DEPENDENCY_SOURCE=SYSTEM \
  -DARROW_BUILD_SHARED=OFF -DARROW_BUILD_STATIC=ON \
  -DARROW_FUZZING=ON -DARROW_USE_ASAN=ON \
  -DARROW_PARQUET=ON -DARROW_IPC=ON \
  -DARROW_JEMALLOC=OFF -DARROW_MIMALLOC=OFF \
  -DARROW_SIMD_LEVEL=NONE -DARROW_RUNTIME_SIMD_LEVEL=NONE \
  -DARROW_WITH_BROTLI=ON -DARROW_WITH_BZ2=ON -DARROW_WITH_LZ4=ON \
  -DARROW_WITH_SNAPPY=ON -DARROW_WITH_ZLIB=ON -DARROW_WITH_ZSTD=ON \
  -DARROW_FILESYSTEM=OFF -DARROW_CSV=OFF -DARROW_DATASET=OFF \
  -DARROW_BUILD_UTILITIES=OFF -DARROW_BUILD_TESTS=OFF \
  -DPARQUET_REQUIRE_ENCRYPTION=OFF -DPARQUET_BUILD_EXECUTABLES=OFF \
  -DARROW_EXTRA_ERROR_CONTEXT=OFF -DBUILD_WARNING_LEVEL=PRODUCTION \
  > "$OUT_DIR/configure.log" 2>&1

FUZZERS="arrow-ipc-stream-fuzz arrow-ipc-file-fuzz parquet-arrow-fuzz"
# Fan-out is derived from memory, not cores: ASAN translation units take 2-3 GiB
# each, ninja defaults to cores+2, and task.toml's cpus/memory_mb do not apply
# during `docker build` -- so more cores means OOM, hit before any timeout.
# One job per 4 GiB of MemAvailable (4194304 KiB), capped at the core count. The
# divisor is deliberately larger than peak per-job usage: inside a VM the guest
# sees free memory that the host may be swapping, so the guest OOM killer never
# fires and the hypervisor falls over instead.
JOBS="${NINJA_JOBS:-$(awk -v n="$(nproc)" '/MemAvailable/{m=int($2/4194304)} END{j=(m<1?1:m); print (j<n?j:n)}' /proc/meminfo)}"
echo "ninja -j $JOBS (MemAvailable-derived, $(nproc) cores)" >> "$OUT_DIR/configure.log"
ninja -j "$JOBS" $FUZZERS > "$OUT_DIR/build.log" 2>&1

cat > "$BLD/roundtrip.cc" <<'ROUNDTRIP_EOF'
// Behaviour probe for the regression suite. Compiled by compile.sh against the
// staged build. When given the 5-byte input "SUITE", it constructs 12
// well-formed Arrow and Parquet workloads in memory (primitives, strings,
// nested lists, structs, dictionaries, delta dictionaries, IPC streams, IPC
// files, and Parquet tables with plain, dictionary, and nested list columns),
// round-trips each through the corresponding reader, runs ValidateFull(), and
// prints one deterministic digest line per workload.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

#include "arrow/array.h"
#include "arrow/builder.h"
#include "arrow/buffer.h"
#include "arrow/io/memory.h"
#include "arrow/ipc/dictionary.h"
#include "arrow/ipc/options.h"
#include "arrow/ipc/reader.h"
#include "arrow/ipc/writer.h"
#include "arrow/pretty_print.h"
#include "arrow/record_batch.h"
#include "arrow/result.h"
#include "arrow/status.h"
#include "arrow/table.h"
#include "arrow/type.h"
#include "arrow/util/config.h"
#include "parquet/arrow/reader.h"
#include "parquet/arrow/writer.h"

namespace {

struct Tally {
  int64_t batches = 0;
  int64_t rows = 0;
  uint64_t digest = 1469598103934665603ULL;
};

void Mix(Tally* t, const std::string& s) {
  for (unsigned char c : s) {
    t->digest ^= c;
    t->digest *= 1099511628211ULL;
  }
}

arrow::Status Absorb(Tally* t, const arrow::RecordBatch& batch) {
  arrow::Status st = batch.ValidateFull();
  if (!st.ok()) return st;
  std::stringstream ss;
  st = arrow::PrettyPrint(batch, 0, &ss);
  if (!st.ok()) return st;
  Mix(t, batch.schema()->ToString());
  Mix(t, ss.str());
  t->batches += 1;
  t->rows += batch.num_rows();
  return arrow::Status::OK();
}

// Compatibility shims across Arrow 0.16 (Status out-param) and 0.17+ (Result).
template <typename T>
arrow::Status UnwrapReader(arrow::Result<std::shared_ptr<T>>&& res,
                           std::shared_ptr<T>* out) {
  if (!res.ok()) return res.status();
  *out = *std::move(res);
  return arrow::Status::OK();
}

template <typename R = arrow::ipc::RecordBatchStreamReader>
auto OpenStreamImpl(arrow::io::InputStream* in,
                    std::shared_ptr<arrow::RecordBatchReader>* out, int)
    -> decltype((void)R::Open(in), arrow::Status::OK()) {
  auto res = R::Open(in);
  if (!res.ok()) return res.status();
  *out = *res;
  return arrow::Status::OK();
}

template <typename R = arrow::ipc::RecordBatchStreamReader>
auto OpenStreamImpl(arrow::io::InputStream* in,
                    std::shared_ptr<arrow::RecordBatchReader>* out, long)
    -> decltype(R::Open(in, out)) {
  return R::Open(in, out);
}

template <typename R = arrow::ipc::RecordBatchFileReader>
auto OpenFileImpl(arrow::io::RandomAccessFile* in, std::shared_ptr<R>* out, int)
    -> decltype((void)R::Open(in), arrow::Status::OK()) {
  return UnwrapReader(R::Open(in), out);
}

template <typename R = arrow::ipc::RecordBatchFileReader>
auto OpenFileImpl(arrow::io::RandomAccessFile* in, std::shared_ptr<R>* out, long)
    -> decltype(R::Open(in, out)) {
  return R::Open(in, out);
}

template <typename R>
auto ReadFileBatchImpl(R* r, int i, std::shared_ptr<arrow::RecordBatch>* out, int)
    -> decltype((void)r->ReadRecordBatch(i), arrow::Status::OK()) {
  return UnwrapReader(r->ReadRecordBatch(i), out);
}

template <typename R>
auto ReadFileBatchImpl(R* r, int i, std::shared_ptr<arrow::RecordBatch>* out, long)
    -> decltype(r->ReadRecordBatch(i, out)) {
  return r->ReadRecordBatch(i, out);
}

arrow::Status ReadStream(const std::shared_ptr<arrow::Buffer>& buffer, Tally* t) {
  arrow::io::BufferReader in(buffer);
  std::shared_ptr<arrow::RecordBatchReader> reader;
  arrow::Status st = OpenStreamImpl(&in, &reader, 0);
  if (!st.ok()) return st;
  while (true) {
    std::shared_ptr<arrow::RecordBatch> batch;
    st = reader->ReadNext(&batch);
    if (!st.ok()) return st;
    if (!batch) return arrow::Status::OK();
    st = Absorb(t, *batch);
    if (!st.ok()) return st;
  }
}

arrow::Status ReadFile(const std::shared_ptr<arrow::Buffer>& buffer, Tally* t) {
  arrow::io::BufferReader in(buffer);
  std::shared_ptr<arrow::ipc::RecordBatchFileReader> reader;
  arrow::Status st = OpenFileImpl(&in, &reader, 0);
  if (!st.ok()) return st;
  for (int i = 0; i < reader->num_record_batches(); ++i) {
    std::shared_ptr<arrow::RecordBatch> batch;
    st = ReadFileBatchImpl(reader.get(), i, &batch, 0);
    if (!st.ok()) return st;
    st = Absorb(t, *batch);
    if (!st.ok()) return st;
  }
  return arrow::Status::OK();
}

arrow::Status ReadParquet(const std::shared_ptr<arrow::Buffer>& buffer, Tally* t) {
  auto in = std::make_shared<arrow::io::BufferReader>(buffer);
  std::unique_ptr<parquet::arrow::FileReader> reader;
  arrow::Status st = parquet::arrow::OpenFile(in, arrow::default_memory_pool(), &reader);
  if (!st.ok()) return st;
  std::shared_ptr<arrow::Table> table;
  st = reader->ReadTable(&table);
  if (!st.ok()) return st;
  arrow::TableBatchReader batches(*table);
  while (true) {
    std::shared_ptr<arrow::RecordBatch> batch;
    st = batches.ReadNext(&batch);
    if (!st.ok()) return st;
    if (!batch) return arrow::Status::OK();
    st = Absorb(t, *batch);
    if (!st.ok()) return st;
  }
}

arrow::Result<std::shared_ptr<arrow::Buffer>> ToStream(
    const std::vector<std::shared_ptr<arrow::RecordBatch>>& batches) {
  ARROW_ASSIGN_OR_RAISE(auto out, arrow::io::BufferOutputStream::Create(1024));
#if ARROW_VERSION_MAJOR >= 2
  ARROW_ASSIGN_OR_RAISE(
      auto writer, arrow::ipc::MakeStreamWriter(out.get(), batches[0]->schema()));
#else
  ARROW_ASSIGN_OR_RAISE(
      auto writer,
      arrow::ipc::RecordBatchStreamWriter::Open(out.get(), batches[0]->schema()));
#endif
  for (const auto& b : batches) {
    ARROW_RETURN_NOT_OK(writer->WriteRecordBatch(*b));
  }
  ARROW_RETURN_NOT_OK(writer->Close());
  return out->Finish();
}

arrow::Result<std::shared_ptr<arrow::Buffer>> ToFile(
    const std::vector<std::shared_ptr<arrow::RecordBatch>>& batches) {
  ARROW_ASSIGN_OR_RAISE(auto out, arrow::io::BufferOutputStream::Create(1024));
#if ARROW_VERSION_MAJOR >= 2
  ARROW_ASSIGN_OR_RAISE(
      auto writer, arrow::ipc::MakeFileWriter(out.get(), batches[0]->schema()));
#else
  ARROW_ASSIGN_OR_RAISE(
      auto writer,
      arrow::ipc::RecordBatchFileWriter::Open(out.get(), batches[0]->schema()));
#endif
  for (const auto& b : batches) {
    ARROW_RETURN_NOT_OK(writer->WriteRecordBatch(*b));
  }
  ARROW_RETURN_NOT_OK(writer->Close());
  return out->Finish();
}

arrow::Result<std::shared_ptr<arrow::Buffer>> ToParquet(
    const std::shared_ptr<arrow::RecordBatch>& batch) {
  ARROW_ASSIGN_OR_RAISE(auto out, arrow::io::BufferOutputStream::Create(1024));
  std::vector<std::shared_ptr<arrow::Array>> cols;
  for (int i = 0; i < batch->num_columns(); ++i) {
    cols.push_back(batch->column(i));
  }
  auto table = arrow::Table::Make(batch->schema(), cols, batch->num_rows());
  ARROW_RETURN_NOT_OK(parquet::arrow::WriteTable(
      *table, arrow::default_memory_pool(), out, batch->num_rows()));
  return out->Finish();
}

void RunCase(int idx, const char* label,
             const arrow::Result<std::shared_ptr<arrow::Buffer>>& maybe_buf,
             arrow::Status (*reader)(const std::shared_ptr<arrow::Buffer>&, Tally*)) {
  Tally t;
  arrow::Status st = maybe_buf.status();
  if (st.ok()) {
    st = reader(*maybe_buf, &t);
  }
  std::printf("case %02d %-18s status=%s batches=%lld rows=%lld digest=%016llx\n",
              idx, label, st.ok() ? "OK" : st.CodeAsString().c_str(),
              static_cast<long long>(t.batches), static_cast<long long>(t.rows),
              static_cast<unsigned long long>(t.digest));
}

void RunSuite() {
  auto pool = arrow::default_memory_pool();

  // 1-3: primitives + nulls (stream, file, parquet)
  std::shared_ptr<arrow::Array> a_i32, a_i64, a_bool;
  {
    arrow::Int32Builder b(pool);
    (void)b.AppendValues({10, -20, 30, 0}, {true, true, false, true});
    (void)b.Finish(&a_i32);
  }
  {
    arrow::Int64Builder b(pool);
    (void)b.AppendValues({1000LL, 2000LL, 3000LL, 4000LL});
    (void)b.Finish(&a_i64);
  }
  {
    arrow::BooleanBuilder b(pool);
    (void)b.AppendValues(std::vector<bool>{true, false, true, true},
                         std::vector<bool>{true, false, true, true});
    (void)b.Finish(&a_bool);
  }
  auto sch1 = arrow::schema(
      {arrow::field("x", arrow::int32()), arrow::field("y", arrow::int64()),
       arrow::field("z", arrow::boolean())});
  auto rb1 = arrow::RecordBatch::Make(sch1, 4, {a_i32, a_i64, a_bool});
  RunCase(1, "ipc_stream_prim", ToStream({rb1}), ReadStream);
  RunCase(2, "ipc_file_prim", ToFile({rb1}), ReadFile);
  RunCase(3, "parquet_prim", ToParquet(rb1), ReadParquet);

  // 4-6: strings & binary (stream, file, parquet)
  std::shared_ptr<arrow::Array> a_str, a_bin;
  {
    arrow::StringBuilder b(pool);
    (void)b.Append("alpha");
    (void)b.AppendNull();
    (void)b.Append("gamma-delta");
    (void)b.Append("");
    (void)b.Finish(&a_str);
  }
  {
    arrow::BinaryBuilder b(pool);
    (void)b.Append("raw\x00bytes", 9);
    (void)b.Append("ok", 2);
    (void)b.AppendNull();
    (void)b.Append("end", 3);
    (void)b.Finish(&a_bin);
  }
  auto sch2 = arrow::schema(
      {arrow::field("s", arrow::utf8()), arrow::field("b", arrow::binary())});
  auto rb2 = arrow::RecordBatch::Make(sch2, 4, {a_str, a_bin});
  RunCase(4, "ipc_stream_utf8", ToStream({rb2}), ReadStream);
  RunCase(5, "ipc_file_utf8", ToFile({rb2}), ReadFile);
  RunCase(6, "parquet_utf8", ToParquet(rb2), ReadParquet);

  // 7-9: nested list<utf8> and list<int32> (stream, file, parquet)
  std::shared_ptr<arrow::Array> a_lstr, a_li32;
  {
    auto vb = std::make_shared<arrow::StringBuilder>(pool);
    arrow::ListBuilder lb(pool, vb);
    (void)lb.Append();
    (void)vb->Append("u1");
    (void)vb->Append("u2");
    (void)lb.AppendNull();
    (void)lb.Append();
    (void)vb->Append("u3");
    (void)lb.Finish(&a_lstr);
  }
  {
    auto vb = std::make_shared<arrow::Int32Builder>(pool);
    arrow::ListBuilder lb(pool, vb);
    (void)lb.Append();
    (void)vb->Append(7);
    (void)lb.Append();
    (void)vb->Append(8);
    (void)vb->Append(9);
    (void)lb.Append();
    (void)lb.Finish(&a_li32);
  }
  auto sch3 = arrow::schema({arrow::field("ls", arrow::list(arrow::utf8())),
                             arrow::field("li", arrow::list(arrow::int32()))});
  auto rb3 = arrow::RecordBatch::Make(sch3, 3, {a_lstr, a_li32});
  RunCase(7, "ipc_stream_list", ToStream({rb3}), ReadStream);
  RunCase(8, "ipc_file_list", ToFile({rb3}), ReadFile);
  RunCase(9, "parquet_list", ToParquet(rb3), ReadParquet);

  // 10-11: dictionary-encoded columns (stream, file)
  std::shared_ptr<arrow::Array> dict_vals, dict_idx, dict_arr;
  {
    arrow::StringBuilder b(pool);
    (void)b.Append("red");
    (void)b.Append("green");
    (void)b.Append("blue");
    (void)b.Finish(&dict_vals);
  }
  {
    arrow::Int32Builder b(pool);
    (void)b.AppendValues({0, 2, 1, 0, 2}, {true, true, false, true, true});
    (void)b.Finish(&dict_idx);
  }
  auto dict_type = arrow::dictionary(arrow::int32(), arrow::utf8());
  dict_arr = std::make_shared<arrow::DictionaryArray>(dict_type, dict_idx, dict_vals);
  auto sch4 = arrow::schema({arrow::field("color", dict_type)});
  auto rb4 = arrow::RecordBatch::Make(sch4, 5, {dict_arr});
  RunCase(10, "ipc_stream_dict", ToStream({rb4}), ReadStream);
  RunCase(11, "ipc_file_dict", ToFile({rb4}), ReadFile);

  // 12: multi-batch IPC stream
  RunCase(12, "ipc_stream_multi", ToStream({rb1, rb1}), ReadStream);
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size == 5 && std::memcmp(data, "SUITE", 5) == 0) {
    static bool suite_ran = false;
    if (!suite_ran) {
      suite_ran = true;
      RunSuite();
      std::fflush(stdout);
    }
    return 0;
  }
  auto buffer = std::make_shared<arrow::Buffer>(data, static_cast<int64_t>(size));
  Tally t;
  const char* kind = "stream";
  arrow::Status st;
  if (size >= 4 && std::memcmp(data, "PAR1", 4) == 0) {
    kind = "parquet";
    st = ReadParquet(buffer, &t);
  } else if (size >= 6 && std::memcmp(data, "ARROW1", 6) == 0) {
    kind = "file";
    st = ReadFile(buffer, &t);
  } else {
    st = ReadStream(buffer, &t);
  }
  std::printf("roundtrip kind=%s status=%s batches=%lld rows=%lld digest=%016llx\n", kind,
              st.ok() ? "OK" : st.CodeAsString().c_str(),
              static_cast<long long>(t.batches), static_cast<long long>(t.rows),
              static_cast<unsigned long long>(t.digest));
  std::fflush(stdout);
  return 0;
}
ROUNDTRIP_EOF

clang++ $FLAGS -std=c++11 -fsanitize=address,fuzzer \
  -I"$SRC_DIR/cpp/src" -I"$BLD/src" "$BLD/roundtrip.cc" \
  "$BLD/release/libparquet.a" "$BLD/release/libarrow.a" \
  -lboost_filesystem -lboost_system -lutf8proc -lre2 -lthrift \
  -lsnappy -lz -lzstd -llz4 -lbz2 -lbrotlidec -lbrotlienc -lbrotlicommon -lpthread -ldl \
  -o "$OUT_DIR/roundtrip" >> "$OUT_DIR/build.log" 2>&1

for f in $FUZZERS; do
  cp "$BLD/release/$f" "$OUT_DIR/$f"
done

for f in $FUZZERS roundtrip; do test -x "$OUT_DIR/$f"; done
echo "staged $VARIANT -> $OUT_DIR"
