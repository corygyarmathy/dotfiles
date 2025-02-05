import sys
from collections import Counter


def main():
    book_path: str = "books/frankenstein.txt"

    # get book text
    try:
        text: str = get_book_text(book_path)
    except (
        BookFileNotFoundError,
        BookFilePermissionError,
        BookFileIsADirectoryError,
    ) as e:  # Specific file error
        print(f"Error: {e}")
        sys.exit(1)  # Exit with error status
    except BookFileError as e:  # General file error
        print(f"Error: {e}")
        sys.exit(1)  # Exit with error status
    except BookError as e:  # Unhandled, general error
        print("Unhandled error!")
        print(f"Error: {e}")
        sys.exit(1)  # Exit with error status

    word_count: int = count_words(text)
    chars_count: Counter[str] = count_alphabetic_characters(text)

    print_report(book_path, word_count, chars_count)


def print_report(path: str, word_count: int, chars_count: Counter[str]):
    """Format and print the report of how many times each character occurs"""
    print(f"--- Begin report of {path} ---")
    print(f"{word_count} words found in the document")
    print()
    for char, count in chars_count.most_common():
        print(f" The '{char}' character was found {count} times")
    print("--- End report ---")


def get_book_text(path: str) -> str:
    """Read the file at *path*, return the file's contents"""
    try:
        with open(path) as open_file:
            return open_file.read()
    except FileNotFoundError:
        raise BookFileNotFoundError(f"No file found at {path}")
    except PermissionError:
        raise BookFilePermissionError(f"Cannot read file at {path}. Check permissions.")
    except IsADirectoryError:
        raise BookFileIsADirectoryError(f"Path {path} is a directory, not a file.")
    except Exception as err:
        raise BookError(f"Unexpected {err=}, {type(err)=}")


def count_words(text: str) -> int:
    """Count the number of words in the text"""
    words = text.split()

    return len(words)


def count_alphabetic_characters(text: str) -> Counter[str]:
    """Count the number of alphabetic characters in the text, converting them all to lowercase"""
    return Counter(char for char in text.lower() if char.isalpha())


class BookError(Exception):
    """Base exception for all book errors"""

    pass


class BookFileError(BookError):
    """Base exception for all book file operations"""

    pass


class BookFileNotFoundError(BookFileError):
    """Raised when book file is not found"""

    pass


class BookFilePermissionError(BookFileError):
    """Raised when program does not have permission to read the book file"""

    pass


class BookFileIsADirectoryError(BookFileError):
    """Raised when the supplied path points to a directory, not a file as required"""

    pass


main()
