<?php
// Fixture for PHP/Bridge/Tests/iserve_bridge_smoke_test.c's request H --
// proves a real multipart/form-data upload populates $_FILES and that
// move_uploaded_file() can move it into a destination within this
// request's own document_root (open_basedir) -- the ROADMAP's "$_FILES
// uploads through PHP" v0.4 deliverable. Not app code; never shipped,
// only ever run by that smoke test. The destination file is deleted
// first (idempotent re-runs) and again at the end (never accumulates
// one in this fixture directory), same pattern as fixtures/sqlite.php.
$destination = __DIR__ . '/uploaded-output.txt';
@unlink($destination);

// Regression check: upload_max_filesize/post_max_size must be set
// explicitly (see iserve_php_bridge_startup's own comment) -- PHP's
// compiled-in default for upload_max_filesize is 2M, well under what
// HTTPServerLimits.maxPHPPostBodyBytes already allows through the
// transport layer, and this fixture's own tiny test upload (well under
// even that old 2M default) would never have caught that gap. Checked
// via ini_get() rather than by actually uploading an 8MB body, which
// would make this smoke test slow for no extra confidence -- the ini
// value is what actually decides the outcome, not the test body size.
echo "upload_max_filesize=" . ini_get('upload_max_filesize') . "\n";
echo "post_max_size=" . ini_get('post_max_size') . "\n";

echo "files_isset=" . (isset($_FILES['file']) ? 'yes' : 'no') . "\n";
if (!isset($_FILES['file'])) {
    exit;
}

echo "upload_error=" . $_FILES['file']['error'] . "\n";
echo "is_uploaded_file=" . (is_uploaded_file($_FILES['file']['tmp_name']) ? 'yes' : 'no') . "\n";

$moved = move_uploaded_file($_FILES['file']['tmp_name'], $destination);
echo "move_uploaded_file=" . ($moved ? 'yes' : 'no') . "\n";

if ($moved) {
    echo "moved_content=" . file_get_contents($destination) . "\n";
}

@unlink($destination);
