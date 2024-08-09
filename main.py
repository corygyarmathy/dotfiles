def main():
    book_path: str = "books/frankenstein.txt"
    text = get_book_text(book_path)
    word_count = get_num_words(text)
    chars_dict = get_chars_dict(text)
    print(f"{word_count} words found in the document")
    print(
        f"The following list the unique characters in the document. \r\n {chars_dict}"
    )


def get_book_text(path: str):
    with open(path) as f:
        return f.read()


def get_num_words(text: str) -> int:
    words = text.split()

    return len(words)


def get_chars_dict(text: str) -> dict[str, int]:
    lowered_string = text.lower()  # Only counting lowercase characters

    char_count: dict[str, int] = {}
    for char in lowered_string:
        if char in char_count:
            char_count[char] += 1
        else:
            char_count[char] = 1
    return char_count


main()
