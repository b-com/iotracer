#include "dentry.h"


/*A work buffer for larger string manipulation, etc. */
unsigned char work_buff[WORK_BUFF_SIZE];
DEFINE_SPINLOCK(work_buff_lock);

struct dentry * get_inode_dentry(struct inode * inode) {

    struct dentry * dentry = NULL;
    struct super_block * sb;


    if (! inode) {
        return NULL;
    }

    sb = inode->i_sb;

    if (sb) {
        if (sb->s_export_op) {

        }
    }


    if ((sb) &&    (sb->s_export_op) &&    (sb->s_export_op->fh_to_dentry)) {
        struct fid fid;
        memset(&fid, 0, sizeof(fid));
        fid.i32.ino = inode->i_ino;
        fid.i32.gen = inode->i_generation;

        dentry = sb->s_export_op->fh_to_dentry(sb, &fid, sizeof(fid.i32), FILEID_INO32_GEN);

        if (IS_ERR(dentry)) {

            dentry = NULL;
        }
    }


    return dentry;
}


/*
 * Given a dentry, build the full path name for the dentry into the buffer
 * supplied by walking up the dentry's parent dentries.
 */
int dentry_full_file_name(struct dentry * dentry, char * buf, int buf_len) {

    struct inode * inode = dentry ? dentry->d_inode : NULL;
    struct dentry * d_parent;
#define MAX_DENTRIES (WORK_BUFF_SIZE / sizeof(struct dentry *))
    struct dentry ** dentries = (struct dentry **) work_buff;
    int i = 0;
    char * p;
    int l;

    buf[0] = '\0';

    if (dentry) {
        struct super_block * sb = inode ? inode->i_sb : NULL;

        spin_lock(&work_buff_lock);
        dentries[i++] = dentry;
        d_parent = dentry->d_parent;
        for (; (d_parent != NULL) &&
                       (d_parent != dentry) &&
                       (i < MAX_DENTRIES); i++) {
            dentries[i] = d_parent;
            dentry = d_parent;
            d_parent = dentry->d_parent;
        }

        dentry = sb->s_root;
        if (dentry) {
            dentries[i++] = dentry;
            d_parent = dentry->d_parent;
            for (; (d_parent != NULL) &&
                           (d_parent != dentry) &&
                           (i < MAX_DENTRIES); i++) {
                dentries[i] = d_parent;
                dentry = d_parent;
                d_parent = dentry->d_parent;
            }
        }

        p = buf;
        l = buf_len;
        for (i--; i >= 0; i--) {
            int len;

            if ((dentries[i]->d_name.name[0] == '\0') ||
                    (dentries[i]->d_name.name[0] == '/')) {
                continue;
            }
            if (l > 1) {
                *p++ = '/';
                l--;
            } else {
                break;
            }
            len = (dentries[i]->d_name.len <= l - 1) ? dentries[i]->d_name.len : l - 1;
            memcpy(p, dentries[i]->d_name.name, len);
            p += len;
            l -= len;
            if (l <= 1) {
                break;
            }
        }
        *p = '\0';
        spin_unlock(&work_buff_lock);
        return p - buf;
    } else {
        return 0;
    }
}