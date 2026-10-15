// Command s3proof puts the avatar policy on Zulip's osl1 buckets and runs the S3 proofs of
// docs/plans/2026-10-zulip.md, decision B, with the AWS SDK tusd v2.9.1 builds with. Run as the `zulip` account,
// the secret in the environment, never an argument:
//
//	AWS_ACCESS_KEY_ID=zulip \
//	AWS_SECRET_ACCESS_KEY="$(sops -d --extract '["stringData"]["SECRET_ACCESS_KEY"]' artifacts/zulip/s3-zulip.enc.yaml)" \
//	go -C artifacts/zulip/s3proof run . policy|prove [-big]
//
// prove writes only under proof/ and deletes everything there, before and after; -big adds one 2 GiB PUT in a
// single request, the S3 plan's step 4. Not part of the artifact.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

const (
	endpoint = "https://dataverket.s3.osl1.dvkt.no"
	region   = "us-east-1"
	uploads  = "zulip-uploads"
	avatars  = "zulip-avatars"
	prefix   = "proof/"
	mib      = 1 << 20
)

// versitygw v1.9.0 combines a policy with the ACL (#2495), so the owner's rights stay in the ACL.
const avatarPolicy = `{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"*"},` +
	`"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::` + avatars + `/*"]}]}`

var passed, failed int

// check records one proof and prints it.
func check(name string, ok bool, format string, args ...any) {
	status := "PASS"
	if ok {
		passed++
	} else {
		failed++
		status = "FAIL"
	}
	fmt.Printf("%s %s: %s\n", status, name, fmt.Sprintf(format, args...))
}

// note prints an observation that is not a proof.
func note(format string, args ...any) {
	fmt.Printf("NOTE %s\n", fmt.Sprintf(format, args...))
}

// newClient returns a path-style client on the osl1 endpoint, with credentials from the environment alone.
func newClient(ctx context.Context) (*s3.Client, error) {
	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(region),
		config.WithSharedConfigFiles([]string{}),
		config.WithSharedCredentialsFiles([]string{}),
	)
	if err != nil {
		return nil, err
	}
	if os.Getenv("AWS_SECRET_ACCESS_KEY") == "" {
		return nil, errors.New("AWS_SECRET_ACCESS_KEY is empty")
	}
	return s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.BaseEndpoint = aws.String(endpoint)
		o.UsePathStyle = true
	}), nil
}

// fetch makes a GET without credentials and returns the status and the response headers.
func fetch(url string, header map[string]string) (int, http.Header, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return 0, nil, err
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode, resp.Header, nil
}

// random returns n random bytes.
func random(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b
}

// put writes one object.
func put(ctx context.Context, c *s3.Client, bucket, key string, body []byte, contentType string) error {
	in := &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String(key), Body: bytes.NewReader(body)}
	if contentType != "" {
		in.ContentType = aws.String(contentType)
	}
	_, err := c.PutObject(ctx, in)
	return err
}

// keys lists every key under the prefix in a bucket.
func keys(ctx context.Context, c *s3.Client, bucket, under string) ([]string, error) {
	var out []string
	pages := s3.NewListObjectsV2Paginator(c, &s3.ListObjectsV2Input{Bucket: aws.String(bucket), Prefix: aws.String(under)})
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, o := range page.Contents {
			out = append(out, aws.ToString(o.Key))
		}
	}
	return out, nil
}

// clean deletes everything under proof/ in both buckets, in batches of at most 1000 keys.
func clean(ctx context.Context, c *s3.Client, report bool) error {
	for _, bucket := range []string{uploads, avatars} {
		all, err := keys(ctx, c, bucket, prefix)
		if err != nil {
			return err
		}
		deleted := 0
		for start := 0; start < len(all); start += 1000 {
			end := min(start+1000, len(all))
			var objects []types.ObjectIdentifier
			for _, k := range all[start:end] {
				objects = append(objects, types.ObjectIdentifier{Key: aws.String(k)})
			}
			out, err := c.DeleteObjects(ctx, &s3.DeleteObjectsInput{
				Bucket: aws.String(bucket), Delete: &types.Delete{Objects: objects}})
			if err != nil {
				return err
			}
			deleted += len(out.Deleted)
		}
		if report && len(all) > 0 {
			check("delete_objects in "+bucket, deleted == len(all), "%d of %d", deleted, len(all))
		}
	}
	return nil
}

// zeroes is a seekable body of n zero bytes, so a 2 GiB PUT needs no 2 GiB of memory or disk. off is atomic
// because progress reads it while the SDK reads the body.
type zeroes struct {
	n   int64
	off atomic.Int64
}

// Read fills p with zeros up to the end of the body.
func (z *zeroes) Read(p []byte) (int, error) {
	off := z.off.Load()
	if off >= z.n {
		return 0, io.EOF
	}
	k := min(int64(len(p)), z.n-off)
	clear(p[:k])
	z.off.Add(k)
	return int(k), nil
}

// Seek moves the read offset.
func (z *zeroes) Seek(offset int64, whence int) (int64, error) {
	switch whence {
	case io.SeekStart:
		z.off.Store(offset)
	case io.SeekCurrent:
		z.off.Add(offset)
	case io.SeekEnd:
		z.off.Store(z.n + offset)
	}
	return z.off.Load(), nil
}

// progress prints how much of the body has been read every ten seconds, until done is closed.
func progress(z *zeroes, start time.Time, done <-chan struct{}) {
	tick := time.NewTicker(10 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-done:
			return
		case <-tick.C:
			sent := z.off.Load()
			elapsed := time.Since(start).Seconds()
			fmt.Printf("     2 GiB PUT: %d of %d MiB, %.1f MiB/s\n", sent/mib, z.n/mib, float64(sent)/mib/elapsed)
		}
	}
}

// policy puts the world-readable policy on the avatar bucket and prints it back.
func policy(ctx context.Context, c *s3.Client) error {
	if _, err := c.PutBucketPolicy(ctx, &s3.PutBucketPolicyInput{
		Bucket: aws.String(avatars), Policy: aws.String(avatarPolicy)}); err != nil {
		return err
	}
	out, err := c.GetBucketPolicy(ctx, &s3.GetBucketPolicyInput{Bucket: aws.String(avatars)})
	if err != nil {
		return err
	}
	fmt.Println(aws.ToString(out.Policy))
	return nil
}

// prove runs the proofs and deletes what they wrote.
func prove(ctx context.Context, c *s3.Client, big bool) error {
	if err := clean(ctx, c, false); err != nil {
		return fmt.Errorf("cleaning before: %w", err)
	}

	// versitygw #2398.
	if err := put(ctx, c, uploads, prefix+"plain.txt", []byte("zulip proof\n"), "text/plain"); err != nil {
		return err
	}
	head, err := c.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(uploads), Key: aws.String(prefix + "plain.txt")})
	if err != nil {
		return err
	}
	encoding := aws.ToString(head.ContentEncoding)
	check("put without aws-chunked", !strings.Contains(encoding, "aws-chunked"), "Content-Encoding=%q", encoding)

	if err := put(ctx, c, uploads, prefix+"six.bin", random(6*mib), ""); err != nil {
		return err
	}
	presigned, err := s3.NewPresignClient(c).PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(uploads), Key: aws.String(prefix + "six.bin"),
		ResponseContentDisposition: aws.String(`attachment; filename="six.bin"`),
	}, s3.WithPresignExpires(5*time.Minute))
	if err != nil {
		return err
	}
	code, header, err := fetch(presigned.URL, nil)
	if err != nil {
		return err
	}
	check("presigned get", code == 200 && strings.Contains(header.Get("Content-Disposition"), "six.bin"),
		"%d, Content-Disposition=%q", code, header.Get("Content-Disposition"))
	code, _, err = fetch(presigned.URL, map[string]string{"Range": "bytes=0-5242879"})
	if err != nil {
		return err
	}
	check("presigned range", code == 206, "%d", code)

	if err := put(ctx, c, avatars, prefix+"avatar.png", []byte("PNG proof"), "image/png"); err != nil {
		return err
	}
	code, _, err = fetch(endpoint+"/"+avatars+"/"+prefix+"avatar.png", nil)
	if err != nil {
		return err
	}
	check("anonymous get on avatars", code == 200, "%d", code)
	code, _, err = fetch(endpoint+"/"+uploads+"/"+prefix+"plain.txt", nil)
	if err != nil {
		return err
	}
	check("anonymous get on uploads refused", code == 403, "%d", code)
	for _, bucket := range []string{uploads, avatars} {
		out, err := c.ListObjectsV2(ctx, &s3.ListObjectsV2Input{Bucket: aws.String(bucket), Prefix: aws.String(prefix)})
		if err != nil {
			return err
		}
		check("owner lists "+bucket, len(out.Contents) > 0, "%d keys", len(out.Contents))
		if out.KeyCount == nil {
			note("ListObjectsV2 on %s has no KeyCount", bucket)
		}
	}

	// Zulip's tusd hook rewrites headers this way (zerver/views/tusd.py).
	if _, err := c.CopyObject(ctx, &s3.CopyObjectInput{
		Bucket: aws.String(uploads), Key: aws.String(prefix + "plain.txt"),
		CopySource:         aws.String(uploads + "/" + prefix + "plain.txt"),
		MetadataDirective:  types.MetadataDirectiveReplace,
		ContentType:        aws.String("text/markdown"),
		ContentDisposition: aws.String(`inline; filename="plain.md"`),
	}); err != nil {
		return err
	}
	head, err = c.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(uploads), Key: aws.String(prefix + "plain.txt")})
	if err != nil {
		return err
	}
	check("copy onto itself", aws.ToString(head.ContentType) == "text/markdown" &&
		strings.Contains(aws.ToString(head.ContentDisposition), "plain.md"),
		"%s, %s", aws.ToString(head.ContentType), aws.ToString(head.ContentDisposition))

	// Multipart the way tusd's s3store does it, not through the SDK's upload manager.
	key := prefix + "multi.bin"
	created, err := c.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{
		Bucket: aws.String(uploads), Key: aws.String(key)})
	if err != nil {
		return err
	}
	var parts []types.CompletedPart
	for n, size := range []int{5 * mib, 3 * mib} {
		part, err := c.UploadPart(ctx, &s3.UploadPartInput{
			Bucket: aws.String(uploads), Key: aws.String(key), UploadId: created.UploadId,
			PartNumber: aws.Int32(int32(n + 1)), Body: bytes.NewReader(random(size)),
		})
		if err != nil {
			return err
		}
		parts = append(parts, types.CompletedPart{ETag: part.ETag, PartNumber: aws.Int32(int32(n + 1))})
	}
	done, err := c.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{
		Bucket: aws.String(uploads), Key: aws.String(key), UploadId: created.UploadId,
		MultipartUpload: &types.CompletedMultipartUpload{Parts: parts},
	})
	if err != nil {
		return err
	}
	check("multipart upload", strings.Contains(aws.ToString(done.ETag), "-"), "%s", aws.ToString(done.ETag))

	for n := range 5 {
		if err := put(ctx, c, uploads, fmt.Sprintf("%spage/%d", prefix, n), []byte("x"), ""); err != nil {
			return err
		}
	}
	pageCount := 0
	pages := s3.NewListObjectsV2Paginator(c, &s3.ListObjectsV2Input{
		Bucket: aws.String(uploads), Prefix: aws.String(prefix + "page/"), MaxKeys: aws.Int32(2)})
	for pages.HasMorePages() {
		if _, err := pages.NextPage(ctx); err != nil {
			return err
		}
		pageCount++
	}
	check("list pages", pageCount == 3, "%d pages", pageCount)

	// The S3 plan's step 4: PutObject is one request through Envoy, which a route request timeout would cut.
	if big {
		const size = 2 << 30
		start := time.Now()
		body := &zeroes{n: size}
		done := make(chan struct{})
		go progress(body, start, done)
		_, err := c.PutObject(ctx, &s3.PutObjectInput{
			Bucket: aws.String(uploads), Key: aws.String(prefix + "big.bin"),
			Body: body, ContentLength: aws.Int64(size),
		})
		close(done)
		if err != nil {
			check("2 GiB in one PUT", false, "%v", err)
		} else {
			head, err := c.HeadObject(ctx, &s3.HeadObjectInput{
				Bucket: aws.String(uploads), Key: aws.String(prefix + "big.bin")})
			if err != nil {
				return err
			}
			check("2 GiB in one PUT", aws.ToInt64(head.ContentLength) == size, "%d bytes in %s",
				aws.ToInt64(head.ContentLength), time.Since(start).Round(time.Second))
		}
	}

	if err := clean(ctx, c, true); err != nil {
		return fmt.Errorf("cleaning after: %w", err)
	}
	fmt.Printf("%d of %d passed\n", passed, passed+failed)
	if failed > 0 {
		return errors.New("a proof failed")
	}
	return nil
}

func main() {
	ctx := context.Background()
	if len(os.Args) < 2 || (os.Args[1] != "policy" && os.Args[1] != "prove") {
		fmt.Fprintln(os.Stderr, "usage: s3proof policy|prove [-big]")
		os.Exit(2)
	}
	c, err := newClient(ctx)
	if err == nil {
		if os.Args[1] == "policy" {
			err = policy(ctx, c)
		} else {
			err = prove(ctx, c, len(os.Args) > 2 && os.Args[2] == "-big")
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "s3proof:", err)
		os.Exit(1)
	}
}
