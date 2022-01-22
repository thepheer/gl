const c = @import("../c.zig");
const std = @import("std");
const av = @import("av.zig");
const util = @import("../util.zig");
const Self = @This();

gif_stream: *c.AVStream,
format_context: *c.AVFormatContext,
codec_context: *c.AVCodecContext,
packet: *c.AVPacket,

pub fn init(file: [*:0]const u8, width: c_int, height: c_int) !Self {
  const fmt = c.av_guess_format("gif", file, "video/gif");
  try av.checkNull(fmt);

  var fmt_ctx: [*c]c.AVFormatContext = undefined;
  try av.checkError(c.avformat_alloc_output_context2(&fmt_ctx, fmt, "gif", file));
  errdefer c.avformat_free_context(fmt_ctx);

  const codec = c.avcodec_find_encoder(c.AV_CODEC_ID_GIF);
  try av.checkNull(codec);

  const stream = c.avformat_new_stream(fmt_ctx, codec);
  try av.checkNull(stream);

  const codec_params = stream.*.codecpar;
  codec_params.*.codec_tag = 0;
  codec_params.*.codec_id = codec.*.id;
  codec_params.*.codec_type = c.AVMEDIA_TYPE_VIDEO;
  codec_params.*.format = c.AV_PIX_FMT_PAL8;
  codec_params.*.width = width;
  codec_params.*.height = height;

  var codec_ctx = c.avcodec_alloc_context3(codec);
  try av.checkNull(codec_ctx);
  errdefer c.avcodec_free_context(&codec_ctx);

  try av.checkError(c.avcodec_parameters_to_context(codec_ctx, codec_params));
  codec_ctx.*.time_base = c.av_make_q(1, 20);

  try av.checkError(c.avcodec_open2(codec_ctx, codec, null));
  try av.checkError(c.avio_open(&fmt_ctx.*.pb, file, c.AVIO_FLAG_WRITE));
  errdefer av.checkError(c.avio_closep(&fmt_ctx.*.pb)) catch unreachable;
  try av.checkError(c.avformat_write_header(fmt_ctx, null));

  var packet = c.av_packet_alloc();
  try av.checkNull(packet);
  errdefer c.av_packet_free(&packet);

  return Self{
    .gif_stream = stream,
    .format_context = fmt_ctx,
    .codec_context = codec_ctx,
    .packet = packet,
  };
}

pub fn deinit(self: *Self) void {
  c.av_packet_free(&util.optional(self.packet));
  c.avcodec_free_context(&util.optional(self.codec_context));
  c.avformat_close_input(&util.optional(self.format_context));
}

pub fn finish(self: *Self) !void {
  try av.checkError(c.av_write_trailer(self.format_context));
  try av.checkError(c.avio_closep(&self.format_context.pb));
}

pub fn allocFrame(self: *Self) !*c.AVFrame {
  var frame = c.av_frame_alloc();
  try av.checkNull(frame);
  errdefer c.av_frame_free(&frame);

  frame.*.format = c.AV_PIX_FMT_PAL8;
  frame.*.width = self.codec_context.width;
  frame.*.height = self.codec_context.height;
  try av.checkError(c.av_frame_get_buffer(frame, 4));

  return frame;
}

pub fn encodeFrame(self: *Self, frame: ?*c.AVFrame) !void {
  try av.checkError(c.avcodec_send_frame(self.codec_context, frame));
  while (try self.receivePacket()) |packet| {
    c.av_packet_rescale_ts(packet, self.codec_context.time_base, self.gif_stream.time_base);
    try av.checkError(c.av_write_frame(self.format_context, packet));
  }
}

fn receivePacket(self: *Self) !?*c.AVPacket {
  switch (c.avcodec_receive_packet(self.codec_context, self.packet)) {
    c.AVERROR_EOF, c.AVERROR(c.EAGAIN) => return null,
    else => |code| {
      try av.checkError(code);
      return self.packet;
    }
  }
}
