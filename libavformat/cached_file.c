/*
 * cached file I/O
 */
#include "libavutil/avstring.h"
#include "libavutil/internal.h"
#include "libavutil/opt.h"
#include "avformat.h"

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdlib.h>
#include "url.h"

/* Some systems may not have S_ISFIFO */
#ifndef S_ISFIFO
#  ifdef S_IFIFO
#    define S_ISFIFO(m) (((m) & S_IFMT) == S_IFIFO)
#  else
#    define S_ISFIFO(m) 0
#  endif
#endif

/* Not available in POSIX.1-1996 */
#ifndef S_ISLNK
#  ifdef S_IFLNK
#    define S_ISLNK(m) (((m) & S_IFLNK) == S_IFLNK)
#  else
#    define S_ISLNK(m) 0
#  endif
#endif

/* Not available in POSIX.1-1996 */
#ifndef S_ISSOCK
#  ifdef S_IFSOCK
#    define S_ISSOCK(m) (((m) & S_IFMT) == S_IFSOCK)
#  else
#    define S_ISSOCK(m) 0
#  endif
#endif

/* standard file protocol */

typedef struct CachedFileContext {
    const AVClass *class;
    int fd;
    FILE * f;
    int buf_size;
    int write_flags;
    unsigned char * buf; 

} CachedFileContext;

static const AVOption cached_file_options[] = {
    { "buf_size", "set cached buffer size", offsetof(CachedFileContext, buf_size), AV_OPT_TYPE_INT, { .i64 = 1048576 /*1MB*/ }, 0, INT_MAX, AV_OPT_FLAG_ENCODING_PARAM },
    { NULL }
};



static const AVClass cached_file_class = {
    .class_name = "cached_file",
    .item_name  = av_default_item_name,
    .option     = cached_file_options,
    .version    = LIBAVUTIL_VERSION_INT,
};

#ifdef CONFIG_CACHED_FILE_PROTOCOL

static int cached_file_read(URLContext *h, unsigned char *buf, int size)
{
    CachedFileContext *c = h->priv_data;
    return (int)fread(buf, 1, (size_t)size, c->f);

}

static int cached_file_write(URLContext *h, const unsigned char *buf, int size)
{
    CachedFileContext *c = h->priv_data; 
    return (int)fwrite(buf, 1, (size_t)size, c->f);
}

static int cached_file_get_handle(URLContext *h)
{
    CachedFileContext *c = h->priv_data;
    return c->fd;
}

static int cached_file_check(URLContext *h, int mask)
{
    int ret = 0;
    const char *filename = h->filename;
    av_strstart(filename, "file:", &filename);

    {

    struct stat st;
    ret = stat(filename, &st);
    if (ret < 0)
        return AVERROR(errno);

    ret |= st.st_mode&S_IRUSR ? mask&AVIO_FLAG_READ  : 0;
    ret |= st.st_mode&S_IWUSR ? mask&AVIO_FLAG_WRITE : 0;

    }
    return ret;
}

static int cached_file_delete(URLContext *h)
{
    return AVERROR(ENOSYS);
}

static int cached_file_move(URLContext *h_src, URLContext *h_dst)
{
    return AVERROR(ENOSYS);
}

static int64_t cached_file_seek(URLContext *h, int64_t pos, int whence)
{
    CachedFileContext *c = h->priv_data;
    int64_t ret;

    if (whence == AVSEEK_SIZE) {
        struct stat st;
        fflush(c->f);
        ret = fstat(c->fd, &st);
        return ret < 0 ? AVERROR(errno): st.st_size;
    }
    ret = fseeko(c->f, (off_t)pos, whence);
    if (ret){
        av_log(h, AV_LOG_ERROR, "Seek FILE Fail(%d)", errno);
        return AVERROR(errno);
    }
    ret = (int64_t)ftello(c->f);
    return ret < 0 ? AVERROR(errno) : ret;  
 
}

static int cached_file_open(URLContext *h, const char *filename, int flags)
{
    CachedFileContext *c = h->priv_data;
    FILE * f = NULL;
    const char * mode = NULL;

    av_strstart(filename, "cf:", &filename);
    
    if (flags & AVIO_FLAG_WRITE && flags & AVIO_FLAG_READ) {
        mode = "w+b";
        c->write_flags = 1;
    } else if (flags & AVIO_FLAG_WRITE) {
        mode = "wb";
        c->write_flags = 1;
    } else {
        mode = "rb";
        c->write_flags = 0;
    }
    f = fopen(filename, mode);
    if(f == NULL){
        av_log(h, AV_LOG_ERROR, "Open FILE Fail(%d)", errno);
        return AVERROR(errno);
    }
    if(c->buf_size != 0){
        c->buf = (char *)av_malloc(c->buf_size);
        setvbuf(f, c->buf, _IOFBF, (size_t)c->buf_size);    
    }else{
        c->buf = NULL;
    }
    c->f = f;
    c->fd = fileno(f);

    return 0;
}

/* XXX: use llseek */


static int cached_file_close(URLContext *h)
{
    int r;
    CachedFileContext *c = h->priv_data;

    /* flush the file when close */    
    if(c->write_flags){
        fflush(c->f);
        fsync(c->fd);
    }
    r = fclose(c->f);
    if(r){
        return AVERROR(errno);
    }
    av_free(c->buf);
    return 0;
    
}


URLProtocol ff_cached_file_protocol = {
    .name                = "cf",
    .url_open            = cached_file_open,
    .url_read            = cached_file_read,
    .url_write           = cached_file_write,
    .url_seek            = cached_file_seek,
    .url_close           = cached_file_close,
    .url_get_file_handle = cached_file_get_handle,
    .url_check           = cached_file_check,
    .url_delete          = cached_file_delete,
    .url_move            = cached_file_move,
    .priv_data_size      = sizeof(CachedFileContext),
    .priv_data_class     = &cached_file_class,

};

#endif /* CONFIG_CACHED_FILE_PROTOCOL */

