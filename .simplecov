# Read by bashcov. Only the helper script is product code; bats and the fake
# gh in test/ are traced too because bashcov follows every bash child.
SimpleCov.configure do
  skip { |file| !file.filename.end_with?("/pull-requests.sh") }
  coverage_dir "coverage/bash"
end
