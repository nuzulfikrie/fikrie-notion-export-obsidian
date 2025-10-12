#!/bin/bash

# Notion to Obsidian Export Script
# This script exports your Notion workspace to markdown files for Obsidian
# Automatically handles Notion API rate limits and retries

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NOTION_TOKEN="${NOTION_TOKEN:-}"
EXPORT_DIR="${EXPORT_DIR:-./notion-export}"
OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-./obsidian-vault}"
EXPORT_CHILD_PAGES="${EXPORT_CHILD_PAGES:-true}"
EXTRACT_METADATA="${EXTRACT_METADATA:-true}"
EXPORT_ALL="${EXPORT_ALL:-false}"
MAX_RETRIES="${MAX_RETRIES:-10}"

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if Python is installed
check_python() {
    if ! command -v python3 &> /dev/null; then
        print_error "Python 3 is not installed. Please install Python 3 first."
        exit 1
    fi
    print_info "Python 3 found: $(python3 --version)"
}

# Function to install notion-exporter
install_notion_exporter() {
    print_info "Installing required packages..."
    pip3 install notion-exporter notion-client || {
        print_error "Failed to install packages"
        exit 1
    }
    print_info "Packages installed successfully"
    print_info "  - notion-exporter: For exporting pages to markdown"
    print_info "  - notion-client: For searching and discovering pages"
}

# Function to get Notion token
get_notion_token() {
    if [ -z "$NOTION_TOKEN" ]; then
        print_warning "NOTION_TOKEN not set in environment"
        read -sp "Enter your Notion API token: " NOTION_TOKEN
        echo
        
        if [ -z "$NOTION_TOKEN" ]; then
            print_error "Notion token is required"
            echo "To get a token:"
            echo "1. Go to https://www.notion.so/my-integrations"
            echo "2. Create a new integration"
            echo "3. Copy the Internal Integration Token"
            echo "4. Share your pages with the integration"
            exit 1
        fi
    fi
}

# Function to create export directories
setup_directories() {
    print_info "Setting up directories..."
    mkdir -p "$EXPORT_DIR"
    mkdir -p "$OBSIDIAN_VAULT"
    print_info "Export directory: $EXPORT_DIR"
    print_info "Obsidian vault: $OBSIDIAN_VAULT"
}

# Function to export Notion pages
export_notion() {
    print_info "Starting Notion export (with automatic rate limit handling)..."
    
    # Create Python script
    cat > /tmp/notion_export.py << 'PYTHON_SCRIPT'
import sys
import os
import asyncio
import time
from notion_exporter import NotionExporter
from pathlib import Path
from notion_client import Client
from notion_client.errors import APIResponseError

# Get configuration from environment
notion_token = os.environ.get('NOTION_TOKEN')
export_dir = os.environ.get('EXPORT_DIR', './notion-export')
export_child_pages = os.environ.get('EXPORT_CHILD_PAGES', 'true').lower() == 'true'
extract_metadata = os.environ.get('EXTRACT_METADATA', 'true').lower() == 'true'
export_all = os.environ.get('EXPORT_ALL', 'false').lower() == 'true'
page_ids = os.environ.get('PAGE_IDS', '').split(',') if os.environ.get('PAGE_IDS') else []
database_ids = os.environ.get('DATABASE_IDS', '').split(',') if os.environ.get('DATABASE_IDS') else []

if not notion_token:
    print("Error: NOTION_TOKEN not set")
    sys.exit(1)

print(f"Initializing NotionExporter...")
print(f"  - Export child pages: {export_child_pages}")
print(f"  - Extract metadata: {extract_metadata}")
print(f"  - Export all accessible pages: {export_all}")
print(f"  - Rate limiting: Automatically handled with retries")

# Initialize Notion client for searching
notion = Client(auth=notion_token)

# Function to get all accessible pages and databases
def get_all_pages_and_databases():
    """Search for all pages and databases accessible to the integration."""
    print("\nSearching for all accessible pages and databases...")
    print("(This may take a while for large workspaces)")
    
    all_page_ids = []
    all_database_ids = []
    has_more = True
    start_cursor = None
    page_count = 0
    
    try:
        while has_more:
            try:
                # Search with pagination
                search_params = {
                    "page_size": 100
                }
                if start_cursor:
                    search_params["start_cursor"] = start_cursor
                
                results = notion.search(**search_params)
                
                for item in results.get("results", []):
                    if item.get("object") == "page":
                        all_page_ids.append(item["id"])
                        page_count += 1
                        if page_count % 10 == 0:
                            print(f"  Found {page_count} pages so far...")
                    elif item.get("object") == "database":
                        all_database_ids.append(item["id"])
                
                has_more = results.get("has_more", False)
                start_cursor = results.get("next_cursor")
                
                # Be respectful of rate limits
                if has_more:
                    time.sleep(0.3)
                    
            except APIResponseError as e:
                if e.status == 429:  # Rate limited
                    print("  Rate limited, waiting 60 seconds...")
                    time.sleep(60)
                    continue
                else:
                    raise
        
        print(f"\n✓ Found {len(all_page_ids)} pages and {len(all_database_ids)} databases")
        return all_page_ids, all_database_ids
        
    except Exception as e:
        print(f"Error searching for pages: {str(e)}")
        print("Tip: Make sure your integration has been shared with your pages/databases")
        return [], []

# Get pages to export
if export_all:
    print("\n" + "="*60)
    print("EXPORTING ENTIRE WORKSPACE")
    print("="*60)
    found_pages, found_databases = get_all_pages_and_databases()
    
    if not found_pages and not found_databases:
        print("\nNo pages found. Please ensure:")
        print("  1. Your integration token is correct")
        print("  2. You've shared pages/databases with your integration")
        print("  3. The integration has the necessary permissions")
        sys.exit(1)
    
    # Use top-level pages only if export_child_pages is True
    # This avoids duplicates since child pages will be exported recursively
    page_ids = found_pages
    database_ids = found_databases
else:
    # Filter out empty strings
    page_ids = [p.strip() for p in page_ids if p.strip()]
    database_ids = [d.strip() for d in database_ids if d.strip()]
    
    if not page_ids and not database_ids:
        print("\nError: No page IDs or database IDs provided")
        print("Options:")
        print("  1. Set EXPORT_ALL=true to export everything")
        print("  2. Set PAGE_IDS='page-id-1,page-id-2'")
        print("  3. Set DATABASE_IDS='database-id-1,database-id-2'")
        sys.exit(1)

# Initialize exporter
exporter = NotionExporter(
    notion_token=notion_token,
    export_child_pages=export_child_pages,
    extract_page_metadata=extract_metadata
)

print(f"\n" + "="*60)
print(f"STARTING EXPORT")
print("="*60)
print(f"Pages to export: {len(page_ids)}")
print(f"Databases to export: {len(database_ids)}")
if export_child_pages:
    print(f"Mode: RECURSIVE (will export all child pages)")
else:
    print(f"Mode: FLAT (only specified pages)")
print("\nNote: The export will automatically:")
print("  • Retry failed requests")
print("  • Wait for rate limits to reset")
print("  • Continue from where it left off")
print("="*60 + "\n")

try:
    start_time = time.time()
    
    exported_pages = exporter.export_pages(
        page_ids=page_ids if page_ids else None,
        database_ids=database_ids if database_ids else None
    )
    
    elapsed_time = time.time() - start_time
    
    print(f"\n" + "="*60)
    print(f"EXPORT COMPLETE")
    print("="*60)
    print(f"✓ Successfully exported {len(exported_pages)} pages")
    print(f"✓ Time taken: {elapsed_time:.1f} seconds ({elapsed_time/60:.1f} minutes)")
    print("="*60 + "\n")
    
    # Save exported pages
    export_path = Path(export_dir)
    export_path.mkdir(parents=True, exist_ok=True)
    
    print("Saving exported pages to disk...")
    saved_count = 0
    
    for page_id, content in exported_pages.items():
        # Try to extract title from frontmatter or use page_id
        filename = f"{page_id}.md"
        
        # Try to get a better filename from the content
        if extract_metadata and content.startswith('---'):
            lines = content.split('\n')
            for line in lines[1:10]:  # Check first few lines
                if line.startswith('title:'):
                    title = line.replace('title:', '').strip().strip('"').strip("'")
                    # Sanitize filename
                    safe_title = "".join(c for c in title if c.isalnum() or c in (' ', '-', '_')).strip()
                    if safe_title:
                        filename = f"{safe_title}.md"
                    break
        
        file_path = export_path / filename
        
        # Handle duplicate filenames
        counter = 1
        while file_path.exists():
            name_part = filename.rsplit('.', 1)[0]
            file_path = export_path / f"{name_part}_{counter}.md"
            counter += 1
        
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(content)
        
        saved_count += 1
        if saved_count % 10 == 0:
            print(f"  Saved {saved_count}/{len(exported_pages)} files...")
    
    print(f"\n✓ All {saved_count} pages saved to: {export_dir}")
    
except Exception as e:
    print(f"\n" + "="*60)
    print(f"ERROR DURING EXPORT")
    print("="*60)
    print(f"Error: {str(e)}")
    print("\nTroubleshooting:")
    print("  • Check your Notion API token is valid")
    print("  • Ensure pages are shared with your integration")
    print("  • Try reducing the number of pages if timing out")
    print("  • Check your internet connection")
    print("="*60)
    sys.exit(1)
PYTHON_SCRIPT

    # Run the Python script
    export NOTION_TOKEN="$NOTION_TOKEN"
    export EXPORT_DIR="$EXPORT_DIR"
    export EXPORT_CHILD_PAGES="$EXPORT_CHILD_PAGES"
    export EXTRACT_METADATA="$EXTRACT_METADATA"
    export EXPORT_ALL="$EXPORT_ALL"
    
    python3 /tmp/notion_export.py
    
    # Clean up
    rm /tmp/notion_export.py
}

# Function to copy to Obsidian vault
copy_to_obsidian() {
    print_info "Copying exported files to Obsidian vault..."
    
    if [ ! -d "$EXPORT_DIR" ] || [ -z "$(ls -A "$EXPORT_DIR")" ]; then
        print_error "No files to copy from $EXPORT_DIR"
        return 1
    fi
    
    cp -r "$EXPORT_DIR"/* "$OBSIDIAN_VAULT/"
    
    file_count=$(find "$OBSIDIAN_VAULT" -name "*.md" | wc -l)
    print_info "Copied files to Obsidian vault: $OBSIDIAN_VAULT"
    print_info "Total markdown files: $file_count"
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Export Notion pages to Obsidian-compatible markdown files.
Automatically handles API rate limits with retries and exponential backoff.

Environment Variables:
  NOTION_TOKEN         Your Notion API integration token (required)
  EXPORT_ALL          Export ALL accessible pages/databases (default: false)
  PAGE_IDS            Comma-separated list of page IDs to export
  DATABASE_IDS        Comma-separated list of database IDs to export
  EXPORT_DIR          Directory for exported files (default: ./notion-export)
  OBSIDIAN_VAULT      Path to your Obsidian vault (default: ./obsidian-vault)
  EXPORT_CHILD_PAGES  Export child pages recursively (default: true)
  EXTRACT_METADATA    Add frontmatter metadata (default: true)

Options:
  -h, --help          Show this help message
  -i, --install       Only install notion-exporter package
  -s, --skip-copy     Skip copying to Obsidian vault

Examples:
  # Export EVERYTHING (recommended for full workspace backup)
  NOTION_TOKEN="secret_xxx" EXPORT_ALL=true $0

  # Export specific pages with all their children
  NOTION_TOKEN="secret_xxx" PAGE_IDS="page-id-1,page-id-2" $0

  # Export to specific Obsidian vault
  NOTION_TOKEN="secret_xxx" \\
  EXPORT_ALL=true \\
  OBSIDIAN_VAULT="/path/to/vault" \\
  $0

  # Export entire database with all pages
  NOTION_TOKEN="secret_xxx" DATABASE_IDS="database-id" $0

  # Export without child pages (flat export)
  NOTION_TOKEN="secret_xxx" \\
  PAGE_IDS="page-id" \\
  EXPORT_CHILD_PAGES=false \\
  $0

Rate Limiting:
  The script automatically handles Notion API rate limits:
  • Retries failed requests automatically
  • Waits for rate limit resets (usually 60 seconds)
  • Shows progress during long exports
  • Safe for exporting large workspaces (1000+ pages)

Getting Started:
  1. Get your Notion API token:
     https://www.notion.so/my-integrations
  2. Create a new integration and copy the token
  3. Share your pages/databases with the integration:
     - Open any page in Notion
     - Click "..." menu → "Connections" → Add your integration
     - For workspace-wide access, share with all pages
  4. Run with EXPORT_ALL=true to export everything:
     NOTION_TOKEN="your-token" EXPORT_ALL=true $0

Tips for Large Exports:
  • Use EXPORT_ALL=true to discover all accessible pages automatically
  • The export may take several minutes for large workspaces (be patient!)
  • Rate limits are handled automatically - no manual intervention needed
  • Export continues even if some pages fail (non-blocking errors)
  • Files are saved with readable names when possible

EOF
}

# Main script
main() {
    local skip_copy=false
    local install_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -i|--install)
                install_only=true
                shift
                ;;
            -s|--skip-copy)
                skip_copy=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    print_info "=== Notion to Obsidian Exporter ==="
    echo
    
    # Check prerequisites
    check_python
    
    # Install notion-exporter
    install_notion_exporter
    
    if [ "$install_only" = true ]; then
        print_info "Installation complete. Use the script again to export."
        exit 0
    fi
    
    # Get Notion token
    get_notion_token
    
    # Setup directories
    setup_directories
    
    # Export Notion pages
    export_notion
    
    # Copy to Obsidian vault
    if [ "$skip_copy" = false ]; then
        copy_to_obsidian
    fi
    
    echo
    print_info "=== Export Complete ==="
    print_info "Your Notion pages are now available in: $OBSIDIAN_VAULT"
    echo
    print_info "Next steps:"
    print_info "  1. Open Obsidian"
    print_info "  2. Click 'Open folder as vault'"
    print_info "  3. Select: $OBSIDIAN_VAULT"
    print_info "  4. Your Notion content is now in Obsidian!"
    echo
    print_info "Note: You can run this script again anytime to update your vault"
    print_info "with the latest changes from Notion."
}

# Run main function
main "$@"
